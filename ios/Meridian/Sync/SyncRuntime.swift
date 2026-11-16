//
//  SyncRuntime.swift
//  Meridian — lifetime container for the sync machinery.
//  OWNER: agenda/sync engineer.
//
//  Owns: the poll loop, the SSE listener, the offline mutation queue and the
//  bookkeeping those three share. Owned by AppModel, never touched by views.
//
//  Everything mutable about a sync lives here rather than in the engine, so the
//  engine stays a set of pure functions over (model, runtime) and there is one
//  copy of the truth to inspect in a bug report.
//

import Foundation

@MainActor
final class SyncRuntime {
    var pollTask: Task<Void, Never>?
    var streamTask: Task<Void, Never>?
    /// Mutations made while offline, replayed in order when the network returns.
    var outbox: [PendingMutation] = []
    var lastEventID: String?

    // MARK: Sync bookkeeping

    /// Server revision from the last snapshot. Shown in the server panel; it is
    /// the cheapest way for a human to tell "did the deck update".
    var lastRev: Int?

    /// True while the SSE link is open. The poll loop uses it to decide whether
    /// to report `.live` (realtime is up) or `.polling` (safety net only).
    var streamConnected = false

    /// Consecutive SSE reconnect attempts: drives the 1→2→4…→30s backoff.
    var streamAttempt = 0

    /// Consecutive poll failures. Multiplies the poll interval so a server that
    /// is down for an hour is not asked 40 times.
    var pollBackoff = 0

    /// Guards the outbox: two flushes racing over the same queue would send the
    /// same mutation twice and drop the second result.
    var isFlushing = false

    /// Set while the app is backgrounded. SSE must not reconnect there — iOS
    /// would kill the socket anyway and each retry burns a wake-up.
    var streamSuspended = false

    /// NotificationCentre tokens for the foreground/background transitions.
    var lifecycleTokens: [NSObjectProtocol] = []

    func cancelAll() {
        pollTask?.cancel()
        streamTask?.cancel()
        pollTask = nil
        streamTask = nil
    }
}

/// One queued write. `deletion` is separate from `body.deleted` on purpose: the
/// wire call differs (DELETE vs PATCH) even though both end up as a tombstone.
struct PendingMutation: Codable, Identifiable {
    var id: String = UUID().uuidString
    var taskID: String
    var body: TaskMutation
    var deletion: Bool
    var createdAt: Date = Date()
}
