//
//  AppModel+Sync.swift
//  Meridian — the sync face of the store. OWNER: agenda/sync engineer.
//
//  The rest of the app calls exactly five things:
//    bootstrapSync()          launch (.task in RootView)
//    restartSyncIfNeeded()    config change, and return to foreground
//    syncNow()                the manual refresh button
//    pushMutation(_:)         every local mutation
//    sendDeletion(_:)         delete
//
//  All of them are MainActor (AppModel is), so the UI never sees a background
//  thread touch the agenda. Network work is done inside SyncEngine.
//

import Foundation
import UIKit

extension AppModel {

    // MARK: - Lifecycle

    /// Starts the two loops if, and only if, there is a server to talk to and
    /// the user asked for automatic sync. Without a base URL the agenda stays a
    /// local file and nothing here costs anything.
    func bootstrapSync() {
        installSyncLifecycleObservers()

        // Teach the session which host may present a self-signed certificate
        // before any request is made. Only that host is trusted; everything else
        // keeps the default evaluation.
        TrustingSession.shared.update(
            host: config.endpoint?.host,
            allowSelfSigned: settings.allowSelfSignedCertificates
        )

        guard config.isConfigured, config.autoSync else {
            runtime.cancelAll()
            runtime.streamConnected = false
            syncPhase = .idle
            return
        }

        if runtime.pollTask == nil {
            runtime.pollTask = Task { [weak model = self] in
                await SyncEngine.pollLoop(model)
            }
        }
        if runtime.streamTask == nil {
            runtime.streamTask = Task { [weak model = self] in
                await SyncEngine.streamLoop(model)
            }
        }
    }

    /// Config edits and returning to the foreground both land here: tear the old
    /// loops down and rebuild them against the current config. Backoff counters
    /// reset because the reason for them is usually exactly what changed.
    func restartSyncIfNeeded() {
        runtime.cancelAll()
        runtime.streamConnected = false
        runtime.streamAttempt = 0
        runtime.pollBackoff = 0
        bootstrapSync()
    }

    /// Manual refresh. Deliberately not `async`: the button wants a transient
    /// "syncing" state, not a blocked tap handler.
    func syncNow() {
        guard config.isConfigured else { return }
        syncPhase = .syncing
        Task { [weak self] in
            guard let self else { return }
            await SyncEngine.flush(self)
            await SyncEngine.pullSnapshot(self)
        }
    }

    // MARK: - Outbound

    func pushMutation(_ task: AgendaTask) {
        guard config.isConfigured else { return }
        enqueue(WireCodec.mutation(for: task), deletion: false)
    }

    func sendDeletion(_ id: String) {
        guard config.isConfigured else { return }
        enqueue(WireCodec.deletion(id: id), deletion: true)
    }

    /// One queue keyed by task id: the newest local intent replaces the older
    /// one, so toggle-toggle-delete collapses into a single request instead of
    /// three racing ones.
    private func enqueue(_ mutation: TaskMutation, deletion: Bool) {
        if let index = runtime.outbox.firstIndex(where: { $0.taskID == mutation.id }) {
            // A queued deletion supersedes any later edit: the task is gone, and
            // an edit must never resurrect it.
            if runtime.outbox[index].deletion { return }
            runtime.outbox[index].body = mutation
            runtime.outbox[index].deletion = deletion
            runtime.outbox[index].createdAt = Date()
        } else {
            runtime.outbox.append(
                PendingMutation(
                    id: UUID().uuidString,
                    taskID: mutation.id,
                    body: mutation,
                    deletion: deletion,
                    createdAt: Date()
                )
            )
        }
        kick()
    }

    /// Fire-and-forget drain. A failed flush already moved the phase to
    /// `.offline`; a successful one leaves the badge alone so it does not blink
    /// on every tap.
    private func kick() {
        Task { [weak self] in
            guard let self else { return }
            await SyncEngine.flush(self)
        }
    }

    // MARK: - Foreground / background

    /// RootView reports `.active`; background only arrives as a notification, and
    /// that is the one place the SSE link has to be parked.
    private func installSyncLifecycleObservers() {
        guard runtime.lifecycleTokens.isEmpty else { return }
        let center = NotificationCenter.default

        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseSyncForBackground()
            }
        }

        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeSyncFromBackground()
            }
        }

        runtime.lifecycleTokens = [background, foreground]
    }

    private func pauseSyncForBackground() {
        runtime.streamSuspended = true
        runtime.streamConnected = false
        runtime.streamTask?.cancel()
        runtime.streamTask = nil
        runtime.pollTask?.cancel()
        runtime.pollTask = nil
    }

    private func resumeSyncFromBackground() {
        runtime.streamSuspended = false
        restartSyncIfNeeded()
    }
}
