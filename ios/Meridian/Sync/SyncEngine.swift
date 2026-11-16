//
//  SyncEngine.swift
//  Meridian — the sync state machine. OWNER: agenda/sync engineer.
//
//  Three loops, one queue, one merge rule:
//    • poll    — a snapshot every `config.syncInterval` seconds (the safety net)
//    • stream  — SSE for the realtime path, exponential backoff on drops
//    • flush   — replays the outbox, survives being offline for hours
//  Merge rule: last writer wins by `updatedAt`, except that anything still
//  sitting in the outbox wins over the server, because the user's tap has not
//  reached it yet.
//
//  The engine holds no state of its own: every fact lives in AppModel or
//  SyncRuntime, and every function here runs on the main actor. Network waits
//  are awaited, so the main thread is only busy while merging.
//

import Foundation

@MainActor
enum SyncEngine {

    // MARK: - Poll loop

    /// Runs until cancelled. Every iteration flushes first, then pulls: a queued
    /// tap should reach the server before the snapshot that would overwrite it.
    static func pollLoop(_ model: AppModel?) async {
        while !Task.isCancelled {
            var interval: Double = 90
            // Scoped so the strong reference is not held across the sleep:
            // runtime -> pollTask -> closure must never keep the store alive.
            do {
                guard let store = model else { return }
                interval = store.config.syncInterval
                await flush(store)
                await pullSnapshot(store)
                let backoff = min(pow(2, Double(store.runtime.pollBackoff)), 16)
                interval = max(15, interval) * backoff
            }
            if Task.isCancelled { return }
            let seconds = min(interval, 900)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - Snapshot

    static func pullSnapshot(_ model: AppModel) async {
        guard let url = WireCodec.endpoint(model.config, WireCodec.Path.snapshot) else { return }
        let request = WireCodec.request(url, method: "GET", token: model.config.token, timeout: 12)

        do {
            let (data, response) = try await TrustingSession.shared.client.data(for: request)
            if Task.isCancelled { return }
            guard let http = response as? HTTPURLResponse else {
                model.syncPhase = .offline
                return
            }

            switch http.statusCode {
            case 200...299:
                break
            case 401, 403:
                model.syncPhase = .failed("鉴权失败")
                model.syncDetail = "口令不对（HTTP \(http.statusCode)）：检查服务器上的 MERIDIAN_TOKEN"
                model.runtime.cancelAll()
                return
            case 429, 500...599:
                model.runtime.pollBackoff = min(model.runtime.pollBackoff + 1, 4)
                model.syncPhase = .offline
                model.syncDetail = "服务器暂时不可用（HTTP \(http.statusCode)）"
                return
            default:
                model.syncPhase = .failed("服务器返回 \(http.statusCode)")
                model.syncDetail = "地址可能不在 /meridian 上（HTTP \(http.statusCode)）"
                return
            }

            let payload: SnapshotPayload
            do {
                payload = try WireCodec.makeDecoder().decode(SnapshotPayload.self, from: data)
            } catch {
                model.syncPhase = .failed("数据格式不符")
                return
            }

            applySnapshot(payload, to: model)
            model.runtime.lastRev = payload.rev
            model.runtime.pollBackoff = 0
            model.lastSyncedAt = Date()
            model.syncDetail = nil
            model.syncPhase = model.runtime.streamConnected ? .live(Date()) : .polling(Date())
            model.persist()
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            if Task.isCancelled { return }
            model.runtime.pollBackoff = min(model.runtime.pollBackoff + 1, 4)
            model.syncPhase = .offline
            model.syncDetail = describe(error)
        }
    }

    /// Turn a transport failure into the sentence that tells the user what to
    /// change. The phase alone ("离线") cannot distinguish a wrong address from
    /// a blocked plaintext request from an untrusted certificate.
    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS 的 ATS 阻止了明文 HTTP：这个安装包太旧，请重装最新 IPA"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .secureConnectionFailed, .serverCertificateHasUnknownRoot:
            return "证书不受信任：打开「信任自签名证书」，或把地址换成 http://"
        case .cannotFindHost:
            return "域名解析失败：地址写错了？"
        case .cannotConnectToHost:
            return "连不上主机：确认 http:// 前缀和端口"
        case .timedOut:
            return "请求超时：服务器没响应，检查地址是否带 /meridian"
        case .notConnectedToInternet:
            return "iPad 没有联网"
        case .unsupportedURL:
            return "地址格式不对：应形如 http://192.168.1.10:8787/meridian"
        default:
            return "网络错误 \(urlError.code.rawValue)：\(urlError.localizedDescription)"
        }
    }

    // MARK: - Outbound queue

    /// Drains the outbox in order. Stops at the first transient failure and
    /// leaves the rest queued; a permanent rejection drops that one item so a
    /// single bad body cannot wedge the queue forever.
    static func flush(_ model: AppModel) async {
        guard model.config.isConfigured, !model.runtime.isFlushing else { return }
        model.runtime.isFlushing = true
        defer { model.runtime.isFlushing = false }

        while let pending = model.runtime.outbox.first {
            if Task.isCancelled { return }
            let delivery = await deliver(pending, model: model)
            switch delivery {
            case .done:
                // Drop the item only if the user did not edit it again while the
                // request was in flight — otherwise the newer tap is still owed
                // to the server and must stay queued.
                if let index = model.runtime.outbox.firstIndex(where: { $0.id == pending.id }),
                   model.runtime.outbox[index].body.updatedAt <= pending.body.updatedAt {
                    model.runtime.outbox.remove(at: index)
                }
            case .retry:
                return
            case .cancel:
                return
            }
        }
    }

    private enum Delivery {
        case done
        case retry      // transient: keep the item, try again next cycle
        case cancel     // fatal: the whole link has to stop
    }

    private static func deliver(_ pending: PendingMutation, model: AppModel) async -> Delivery {
        guard let url = WireCodec.endpoint(model.config, WireCodec.Path.task(pending.taskID)) else {
            return .retry
        }
        var request = WireCodec.request(
            url,
            method: pending.deletion ? "DELETE" : "PATCH",
            token: model.config.token,
            timeout: 12
        )

        if !pending.deletion {
            do {
                request.httpBody = try WireCodec.makeEncoder().encode(pending.body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                // An unencodable body can never succeed; retrying it would block
                // every later mutation behind it.
                model.runtime.outbox.removeAll { $0.id == pending.id }
                return .done
            }
        }

        do {
            let (_, response) = try await TrustingSession.shared.client.data(for: request)
            if Task.isCancelled { return .cancel }
            guard let http = response as? HTTPURLResponse else {
                model.syncPhase = .offline
                return .retry
            }

            switch http.statusCode {
            case 200...299, 404, 410:
                return .done
            case 401, 403:
                model.syncPhase = .failed("鉴权失败")
                model.runtime.cancelAll()
                return .cancel
            case 429, 500...599:
                model.syncPhase = .offline
                return .retry
            default:
                // 400/409/422: the server will never accept this body.
                model.runtime.outbox.removeAll { $0.id == pending.id }
                model.syncPhase = .failed("同步请求被拒绝")
                return .done
            }
        } catch is CancellationError {
            return .cancel
        } catch {
            if Task.isCancelled { return .cancel }
            model.syncPhase = .offline
            return .retry
        }
    }

    // MARK: - Stream loop

    static func streamLoop(_ model: AppModel?) async {
        while !Task.isCancelled {
            var delay: Double = 2
            do {
                guard let store = model else { return }
                if store.runtime.streamSuspended {
                    // Backgrounded: keep the task parked, reconnect on resume.
                    delay = 2
                } else {
                    await streamOnce(store)
                    let attempt = min(store.runtime.streamAttempt, 5)
                    store.runtime.streamAttempt = min(attempt + 1, 5)
                    delay = min(pow(2, Double(attempt)), 30)
                }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    static func streamOnce(_ model: AppModel) async {
        guard model.config.isConfigured else { return }
        guard let url = WireCodec.endpoint(model.config, WireCodec.Path.events) else { return }

        // A long idle timeout: SSE keep-alives reset it, so a 300s value means
        // "the server went quiet", not "the connection is old".
        var request = WireCodec.request(url, method: "GET", token: model.config.token, timeout: 300)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let last = model.runtime.lastEventID {
            // Resuming after a drop: ask for what was missed.
            request.setValue(last, forHTTPHeaderField: "Last-Event-ID")
        }

        let outcome = await SSEClient.connect(
            request: request,
            onOpen: {
                model.runtime.streamConnected = true
                model.runtime.streamAttempt = 0
                model.syncPhase = .live(Date())
            },
            onEvent: { event in
                handle(event, in: model)
            }
        )

        model.runtime.streamConnected = false
        if Task.isCancelled { return }

        switch outcome {
        case .unauthorized:
            model.syncPhase = .failed("鉴权失败")
            model.runtime.cancelAll()
        case .http(let code) where code == 429 || code >= 500:
            model.syncPhase = .offline
        case .http:
            // A 4xx on the stream route (an older server, a missing path) is not
            // a reason to alarm the user: the poll loop is still the source of
            // truth and it will keep the badge honest. Retry at the backoff cap.
            break
        case .closed, .failed:
            // A dropped stream is not an alarm: the poll loop still has the
            // data and the reconnect is already scheduled.
            if model.syncPhase.isConnected { model.syncPhase = .polling(Date()) }
        }
    }

    // MARK: - Merge

    /// Last writer wins per task. Anything queued in the outbox is skipped: the
    /// local edit has not reached the server, so overwriting it would silently
    /// throw away a tap the user just made.
    static func applySnapshot(_ payload: SnapshotPayload, to model: AppModel) {
        let outbox = model.runtime.outbox
        let queued = Set(outbox.map(\.taskID))
        let queuedDeletions = Set(outbox.filter(\.deletion).map(\.taskID))

        var remoteByID: [String: AgendaTask] = [:]
        for task in payload.tasks { remoteByID[task.id] = task }

        var merged: [AgendaTask] = []
        var carried: Set<String> = []

        for local in model.tasks {
            carried.insert(local.id)
            if queued.contains(local.id) {
                merged.append(local)
                continue
            }
            if let fresh = remoteByID[local.id] {
                merged.append(fresh.updatedAt > local.updatedAt ? fresh : local)
            } else if local.origin == .local {
                // Never drop something the server has not seen yet.
                merged.append(local)
            }
            // A remote task missing from a full snapshot was deleted elsewhere.
        }

        for task in payload.tasks where !carried.contains(task.id) && !queuedDeletions.contains(task.id) {
            merged.append(task)
        }

        model.tasks = merged
    }

    static func applyRemote(_ task: AgendaTask, to model: AppModel) {
        if model.runtime.outbox.contains(where: { $0.taskID == task.id }) { return }
        if let index = model.tasks.firstIndex(where: { $0.id == task.id }) {
            guard task.updatedAt > model.tasks[index].updatedAt else { return }
            model.tasks[index] = task
        } else {
            model.tasks.append(task)
        }
        markLive(model)
    }

    static func applyRemoval(id: String, to model: AppModel) {
        if model.runtime.outbox.contains(where: { $0.taskID == id }) { return }
        model.tasks.removeAll { $0.id == id }
        markLive(model)
    }

    private static func markLive(_ model: AppModel) {
        model.runtime.pollBackoff = 0
        model.lastSyncedAt = Date()
        model.syncPhase = .live(Date())
        model.persist()
    }

    // MARK: - Stream events

    static func handle(_ event: SSEEvent, in model: AppModel) {
        if let id = event.id { model.runtime.lastEventID = id }
        guard let data = event.data.data(using: .utf8), !data.isEmpty else { return }
        let decoder = WireCodec.makeDecoder()

        switch event.name {
        case "snapshot", "sync":
            guard let payload = try? decoder.decode(SnapshotPayload.self, from: data) else { return }
            applySnapshot(payload, to: model)
            model.runtime.lastRev = payload.rev
            markLive(model)

        case "task", "update":
            guard let task = try? decoder.decode(AgendaTask.self, from: data) else { return }
            applyRemote(task, to: model)

        case "delete", "deleted", "removed":
            guard let tombstone = try? decoder.decode(WireCodec.Tombstone.self, from: data) else { return }
            applyRemoval(id: tombstone.id, to: model)

        default:
            // Unknown names are tolerated: a newer server may add event kinds,
            // and dropping the connection over one would be worse than ignoring it.
            if let payload = try? decoder.decode(SnapshotPayload.self, from: data) {
                applySnapshot(payload, to: model)
                model.runtime.lastRev = payload.rev
                markLive(model)
            } else if let task = try? decoder.decode(AgendaTask.self, from: data) {
                applyRemote(task, to: model)
            }
        }
    }
}
