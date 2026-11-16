//
//  SSEClient.swift
//  Meridian — server-sent events on top of URLSession.AsyncBytes.
//  OWNER: agenda/sync engineer.
//
//  The 2016-era answer to "live updates" would be a web socket; SSE is enough
//  for a clock that needs to know when a task changed, and it is ten lines of
//  parsing instead of a state machine.
//
//  This type only speaks the protocol. Reconnection policy, model updates and
//  error reporting stay in SyncEngine — one place to reason about the link.
//

import Foundation

/// One dispatched server event. `name` defaults to "message", per the SSE spec.
struct SSEEvent {
    var name: String
    var data: String
    var id: String?
}

@MainActor
enum SSEClient {

    /// How the link ended. `.closed` and `.failed` are both "try again later";
    /// the caller does not need to tell them apart, but the distinction is kept
    /// so a log line is possible later without re-plumbing.
    enum Outcome {
        case closed
        case failed
        case unauthorized
        case http(Int)
    }

    /// Connects, parses events until the stream ends, and returns. Never sleeps
    /// and never reconnects: the caller owns the backoff.
    static func connect(
        request: URLRequest,
        onOpen: () -> Void,
        onEvent: (SSEEvent) -> Void
    ) async -> Outcome {
        var name = "message"
        var data: [String] = []
        var eventID: String?

        // Nested so the parser state stays local; the three fields reset per
        // event exactly as the wire format says they should.
        func dispatch() {
            guard !data.isEmpty else { return }
            let event = SSEEvent(name: name, data: data.joined(separator: "\n"), id: eventID)
            name = "message"
            data.removeAll(keepingCapacity: true)
            eventID = nil
            onEvent(event)
        }

        do {
            let (bytes, response) = try await TrustingSession.shared.client.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                return .unauthorized
            default:
                return .http(http.statusCode)
            }

            onOpen()

            for try await line in bytes.lines {
                if Task.isCancelled { return .closed }
                if line.isEmpty {
                    dispatch()
                    continue
                }
                if line.hasPrefix(":") { continue }   // keep-alive comment
                guard let colon = line.firstIndex(of: ":") else { continue }

                let field = String(line[line.startIndex..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }

                switch field {
                case "event": name = value
                case "data": data.append(value)
                case "id": eventID = value
                default: break                          // "retry:" is the server's business
                }
            }
            return .closed
        } catch {
            // Cancellation is a normal shutdown, not a transport problem.
            if Task.isCancelled { return .closed }
            return .failed
        }
    }
}
