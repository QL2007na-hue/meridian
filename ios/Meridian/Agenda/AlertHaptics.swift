//
//  AlertHaptics.swift
//  Meridian — the physical half of the due-task reminder.
//
//  A 320pt window arriving on a wall clock in a quiet room is easy to miss with
//  the eyes, so the reminder also has to be felt. This owns that layer and
//  nothing else: the view asks for the pattern, and the pattern cannot outlive
//  the view that asked for it.
//
//  Three stages:
//
//    1. entry   — one `.warning`, because the window is an interruption and the
//                 hand should know before the eye does.
//    2. pulse   — 0.22s between impacts for the first 5s, then 1.2s. Fast while
//                 the user is still deciding, slow afterwards so a window left
//                 on the glass for a minute is a presence rather than a pager.
//    3. finish  — one `.success` when the window is closed, then silence.
//
//  Limits are part of the spec: `.rigid` at 0.55 intensity — firm enough to
//  feel through an iPad case, quiet enough not to be an alarm. Every generator
//  is created and fired on the main actor, and the loop is cancelled in
//  `finish()` *and* `stop()` so a tap, an exit and `onDisappear` cannot leave it
//  buzzing after the window is gone.
//

import Combine
import UIKit

/// The haptic pattern of one reminder window.
///
/// `ObservableObject` only so the view can hold it with `@StateObject` — it has
/// no published state. Lifecycle is the contract: `begin()` once on appear,
/// `finish()` on the answer, and `stop()` on the way out. Both `finish()` and
/// `stop()` are idempotent and safe to call in any order.
///
/// Not `@MainActor` on the type: the view creates this eagerly, and an isolated
/// initializer in a nonisolated SwiftUI property initializer is exactly the kind
/// of thing that only fails on CI. The only place that must be on the main actor
/// is the pulse loop, which hops there explicitly.
final class AlertHaptics: ObservableObject {

    private let impact = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()

    private var loop: Task<Void, Never>?
    private var startedAt = Date()
    /// Guards the success pattern against being played twice — the close action
    /// and a fast second tap both funnel through here.
    private var finished = false

    /// The two speeds of the pulse and the point where it changes gear.
    private let fastInterval: TimeInterval = 0.22
    private let slowInterval: TimeInterval = 1.2
    private let fastWindow: TimeInterval = 5
    /// Capped below 0.6 on purpose; see the file comment.
    private let intensity: CGFloat = 0.55

    // MARK: - Lifecycle

    /// Announce arrival and start the pulse.
    func begin() {
        loop?.cancel()
        loop = nil
        finished = false
        startedAt = Date()

        notification.prepare()
        notification.notificationOccurred(.warning)
        impact.prepare()

        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.startedAt)
                let interval = elapsed < self.fastWindow ? self.fastInterval : self.slowInterval
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.impact.impactOccurred(intensity: self.intensity)
                self.impact.prepare()
            }
        }
    }

    /// The user answered. Stop the pulse and confirm the answer exactly once.
    func finish() {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        loop = nil
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    /// The window left the hierarchy without an answer. Never buzz again.
    func stop() {
        loop?.cancel()
        loop = nil
    }
}
