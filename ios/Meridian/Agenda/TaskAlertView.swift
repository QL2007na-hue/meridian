//
//  TaskAlertView.swift
//  Meridian — the due-task reminder, as a small object on the glass.
//
//  Revision 18 turned this from a full-screen dialog into something closer to a
//  device that has just been put down on the screen: a 320pt window above the
//  middle, a title you can read from across the room, and a body that keeps
//  trembling until it is answered. The tremor is the point. A still rectangle is
//  an alert; a thing that keeps nudging itself is a presence.
//
//  Three rules shape the file:
//
//    * No auto-dismiss. The window leaves because a hand said so, never because
//      a timer ran out. There is no dismissal timer anywhere below.
//    * Any tap closes. The scrim is the dismiss target this time — the whole
//      glass is the button. "完成" survives only as an optional shortcut for the
//      one answer that also changes the task.
//    * The tremor is deterministic. Every offset is a pure function of the
//      TimelineView tick, so repainting never re-rolls the dice. `Double.random`
//      per frame is how a comfortable tremble turns into a seizure.
//
//  OWNER: alert/jitter engineer.
//

import Foundation
import SwiftUI

// MARK: - Stage

/// Where the window is in its short life.
///
/// The host owns this, not the window, because the model clears `alertTask`
/// inside its own animation and the exit has to outlive that change by the
/// length of one small fade. The window only renders the stage it is given.
enum AlertStage: Equatable {
    case offStage
    case onStage
    case leaving
}

// MARK: - Host

/// The last overlay in RootView. It owns *presence*; `TaskAlertView` only draws.
///
/// The model hands over a task and later clears it. This keeps a copy on screen
/// for the length of the exit (0.18s of shrink and fade) after the model has
/// already moved on, so the answer is acknowledged visually before the window
/// disappears. `exitHold` is that 0.18s plus two frames of slack.
struct TaskAlertHost: View {
    @EnvironmentObject private var model: AppModel

    /// The task currently drawn. Equals `model.alertTask` except during the exit.
    @State private var onScreen: AgendaTask?
    /// The one animation input the host controls.
    @State private var stage: AlertStage = .offStage

    /// Longer than the 0.18s exit, short enough that a hanging card is noticed.
    private let exitHold: TimeInterval = 0.2

    var body: some View {
        ZStack {
            if let task = onScreen {
                TaskAlertView(task: task, stage: stage) { action in
                    model.resolveAlert(action)
                }
                // A second reminder can arrive while the first is still on the
                // glass. A fresh identity gives the new window its own appear
                // (and its own haptics); without it the loop and the entry
                // animation would be inherited from the previous task.
                .id(task.id)
                .onAppear {
                    // The card must render its off-stage state for one frame or
                    // the entry spring has nothing to travel from.
                    if stage == .offStage { stage = .onStage }
                }
                .zIndex(1)
            }
        }
        // With no card there is no hit area at all: an empty overlay must never
        // swallow the stage's own tap, which is what walks the display stages.
        .allowsHitTesting(onScreen != nil)
        .onAppear { sync(model.alertTask) }
        .onChange(of: model.alertTask?.id) { _, _ in sync(model.alertTask) }
    }

    /// Reconciles "what should be on screen" with "what the model says".
    @MainActor
    private func sync(_ incoming: AgendaTask?) {
        guard let incoming else {
            guard onScreen != nil, stage != .leaving else { return }
            stage = .leaving
            let leavingID = onScreen?.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(exitHold * 1_000_000_000))
                // A second reminder can arrive inside those 200ms — two tasks
                // due in the same minute, or a snooze that lands immediately —
                // and it owns the card now, so do not tear it down.
                guard model.alertTask == nil, onScreen?.id == leavingID else { return }
                onScreen = nil
                stage = .offStage
            }
            return
        }

        if onScreen?.id != incoming.id {
            // Brand-new window. `.offStage` plus the fresh identity lets the
            // child's onAppear flip it, exactly like the first arrival.
            onScreen = incoming
            stage = .offStage
        } else if stage != .onStage {
            // The same task came back (snoozed, then due again) while its card
            // was still fading out: bring it straight back in, no new identity.
            stage = .onStage
        }
    }
}

// MARK: - Window

/// One due task, rendered as a small trembling window.
///
/// Pure view: it reports the answer and the host forwards it to
/// `AppModel.resolveAlert`, so the "完成" button, a tap on the glass and the
/// hardware Escape key all take the same path. Haptics are owned here because
/// their lifetime is this view's lifetime.
struct TaskAlertView: View {
    let task: AgendaTask
    let stage: AlertStage
    let onResolve: (TaskAlertAction) -> Void

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var haptics = AlertHaptics()
    /// One tap, one answer. A second tap during the 0.18s exit is ignored.
    @State private var closing = false

    /// 8Hz is the cadence of the *ticks*, not of the animation: SwiftUI
    /// interpolates between them, so the window never steps.
    private let tickRate: Double = 8

    /// Explicit because a private `@State`/`@StateObject` makes Swift's
    /// synthesised memberwise initializer private, and the host is a different
    /// type even though it lives in this file.
    init(task: AgendaTask, stage: AlertStage, onResolve: @escaping (TaskAlertAction) -> Void) {
        self.task = task
        self.stage = stage
        self.onResolve = onResolve
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(320, proxy.size.width - Space.huge)

            ZStack(alignment: .top) {
                scrim

                // One scheduler for both jobs on this card: the live clock and
                // its lateness text, and the tremor. In Reduce Motion the tick
                // drops to 1Hz and the tremor is bypassed entirely — the window
                // still enters once and then sits still.
                TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 1.0 / tickRate)) { context in
                    let moment = tick(at: context.date)
                    let shake = reduceMotion ? AlertJitter.rest : AlertJitter.shake(at: moment)

                    card(now: context.date)
                        .frame(width: cardWidth)
                        .offset(x: shake.x, y: shake.y)
                        .rotationEffect(.degrees(shake.degrees))
                        // 0.11s at an 8Hz tick: each target is reached just
                        // before the next one is set, so the movement is a
                        // continuous breath instead of a sequence of jumps.
                        .animation(jitterAnimation, value: moment)
                }
                // A timeline view is a layout container; fixing its size keeps
                // the window 320pt wide whatever the ZStack proposes, so the
                // tremor and the entry scale can be applied to the object
                // instead of to a full-screen box.
                .fixedSize()
                // The stage transform is applied to the window alone, then the
                // window is lifted: scaling a view that includes the top padding
                // would make it pivot around a point above the card.
                .offset(y: cardOffset)
                .scaleEffect(cardScale)
                .opacity(cardOpacity)
                .animation(cardAnimation, value: stage)
                // Centre, lifted. Not a dialog: a window an inch above the
                // middle reads as an object standing on the clock face.
                .padding(.top, proxy.size.height * 0.28)
                .zIndex(1)
            }
        }
        .accessibilityAction(named: Text("关闭提醒")) { close(.dismiss) }
        .onAppear { haptics.begin() }
        .onDisappear { haptics.stop() }
        .modifier(HardwareEscape { close(.dismiss) })
    }

    // MARK: Surface

    /// A dark wash, not a blur. The clock behind has to stay legible — telling
    /// the time is most of the app's job — and a full-screen blur every second
    /// is the most expensive thing an always-on iPad could do. Unlike revision
    /// 6 this layer is the dismiss target: the whole glass is the button.
    private var scrim: some View {
        Palette.canvas
            .opacity(stage == .onStage ? 0.58 : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close(.dismiss) }
            .animation(
                stage == .onStage ? Motion.fade : .easeOut(duration: 0.18),
                value: stage
            )
            .accessibilityHidden(true)
    }

    private func card(now: Date) -> some View {
        MeridianCard(padding: Space.l, radius: Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                header(now: now)

                // The title is the reason the window exists; everything below it
                // is context. Two lines is the whole allowance — a reminder that
                // has to be read is an interruption twice.
                Text(task.title)
                    .font(Typeface.title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.s)

                Text(scheduleText(now: now))
                    .font(Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .padding(.top, Space.xs)

                HStack(spacing: Space.s) {
                    Text("点屏幕任意位置关闭")
                        .font(Typeface.micro)
                        .tracking(0.6)
                        .foregroundStyle(Palette.inkQuaternary)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    doneButton
                }
                .padding(.top, Space.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // MeridianCard fills its proposal; a reminder must be exactly as tall as
        // its content, otherwise the window would stretch to the whole stage.
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // Tapping the window closes it too — the whole object is the button.
        // The "完成" button keeps its own gesture; a button's tap is handled by
        // the button, not bubbled to this one.
        .onTapGesture { close(.dismiss) }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            CapsLabel(text: "到点了", accent: true)
            Spacer(minLength: Space.s)
            Text(AgendaFormat.clock(now))
                .font(Typeface.digit(12, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
        }
    }

    /// Optional shortcut: the one answer that also changes the task. Small and
    /// filled with the skin accent, so the eye can find it without it becoming
    /// the only way out.
    private var doneButton: some View {
        Button {
            close(.done)
        } label: {
            Text("完成")
                .font(Typeface.caption)
                .foregroundStyle(Palette.canvas)
                .padding(.horizontal, Space.m)
                .frame(height: Space.xxl)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(skin.accentColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Answers

    /// One funnel for every answer, so the button, a tap on the glass and the
    /// hardware key can never disagree about what closing means.
    private func close(_ action: TaskAlertAction) {
        guard !closing, stage == .onStage else { return }
        closing = true
        // Success is the last thing the hand feels; the pulse must not continue
        // under the fade-out.
        haptics.finish()
        onResolve(action)
    }

    // MARK: Copy

    /// "计划 14:00 · 已超时 3 分钟"
    private func scheduleText(now: Date) -> String {
        guard let due = task.due else { return "未设置时间" }
        let planned = "计划 \(AgendaFormat.clock(due))"
        let late = Int(now.timeIntervalSince(due).rounded(.down))
        guard late >= 1 else { return planned }
        return planned + " · " + lateness(late)
    }

    /// Seconds only during the first minute, then the string goes quiet. A live
    /// seconds counter parked in the corner of the eye is exactly the kind of
    /// nagging this reminder is trying not to be.
    private func lateness(_ seconds: Int) -> String {
        if seconds < 60 { return "已超时 \(seconds) 秒" }
        if seconds < 3_600 { return "已超时 \(seconds / 60) 分钟" }
        if seconds < 86_400 {
            return "已超时 \(seconds / 3_600) 小时 \((seconds % 3_600) / 60) 分钟"
        }
        return "已超时 \(seconds / 86_400) 天"
    }

    // MARK: Motion

    /// One absolute tick per 125ms. Absolute (not "ticks since appear") means the
    /// tremor is the same in every body evaluation and every device — the
    /// window's tremble is a property of the moment, not of the instance.
    private func tick(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate * tickRate).rounded())
    }

    /// The entry is a spring, not a fade: the window is *tossed* onto the glass
    /// and overshoots a couple of points before settling. Reduce Motion keeps it
    /// — it is one gesture, not a loop — while the tremor is dropped entirely.
    private var cardAnimation: Animation {
        stage == .onStage
            ? .spring(response: 0.42, dampingFraction: 0.72)
            : .easeOut(duration: 0.18)
    }

    private var jitterAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.11)
    }

    private var cardOffset: CGFloat {
        stage == .offStage ? -10 : 0
    }

    private var cardScale: CGFloat {
        switch stage {
        case .onStage: return 1
        case .offStage: return 0.9
        case .leaving: return 0.94
        }
    }

    private var cardOpacity: Double {
        stage == .onStage ? 1 : 0
    }
}

// MARK: - Tremor

/// The deterministic pseudo-noise behind the window's tremble.
///
/// What makes it read as "alive" rather than "vibrating" is that it is *not*
/// one sine wave: three hash-sampled octaves — one sampled every tick, one every
/// 3 ticks, one every 13 — are mixed in a fixed ratio, so the motion changes
/// direction at irregular intervals and never repeats a visible cycle. On top of
/// that, once every 40 ticks (5s at 8Hz) a 4pt shove in a freshly hashed
/// direction is layered on and decayed over half a second. The result is: small
/// constant drift, occasional push, back to drift.
///
/// Amplitudes, all in points/degrees:
///   * drift:  2.4 x / 2.2 y, ±0.8°
///   * shove:  4.0 at peak, +0.4° of roll
///
/// It has to stay a pure function of `tick`: a view body can be evaluated many
/// times per second for reasons that have nothing to do with time, and any
/// randomness inside it would make those evaluations visible as a twitch.
enum AlertJitter {

    struct Shake {
        var x: CGFloat
        var y: CGFloat
        var degrees: Double
    }

    /// Reduce Motion uses this: no tremor, no push, a still window.
    static let rest = Shake(x: 0, y: 0, degrees: 0)

    static func shake(at tick: Int) -> Shake {
        let driftX = noise(tick, 0xA1) * 2.4
        let driftY = noise(tick, 0xB2) * 2.2
        let driftDegrees = noise(tick, 0xC3) * 0.8

        let phase = ((tick % 40) + 40) % 40
        let kick = pushEnvelope(phase)
        guard kick > 0 else {
            return Shake(x: CGFloat(driftX), y: CGFloat(driftY), degrees: driftDegrees)
        }

        // One shove every 40 ticks (5s), in a direction re-rolled once per
        // cycle, so it never points the same way twice.
        let cycle = tick / 40
        let angle = hashed(cycle, 0xD4) * 2 * Double.pi
        return Shake(
            x: CGFloat(driftX + cos(angle) * 4.0 * kick),
            y: CGFloat(driftY + sin(angle) * 4.0 * kick),
            degrees: driftDegrees + cos(angle) * 0.4 * kick
        )
    }

    /// 0 → 1 over the first two ticks of a cycle, then a linear decay over the
    /// next thirteen. A shove, not a step: the eye reads the attack, the hand
    /// reads the settle.
    private static func pushEnvelope(_ phase: Int) -> Double {
        if phase < 2 { return Double(phase) / 2 }
        if phase > 15 { return 0 }
        return 1 - Double(phase - 2) / 13
    }

    /// Multi-octave value noise in [-1, 1]. The fast octave carries 58% of the
    /// motion, the slower ones give it a wandering centre of gravity.
    private static func noise(_ tick: Int, _ seed: UInt64) -> Double {
        let fine = hashed(tick, seed)
        let medium = hashed(tick / 3, seed &+ 0x9E37)
        let coarse = hashed(tick / 13, seed &+ 0xC2B2)
        return (fine * 0.58 + medium * 0.30 + coarse * 0.12) * 2 - 1
    }

    /// SplitMix-style integer finaliser → uniform in [0, 1). Deterministic
    /// across launches and devices, and cheap enough to run a few times per
    /// tick without touching the frame budget.
    private static func hashed(_ index: Int, _ seed: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(index)) &+ seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

// MARK: - Escape

/// Esc closes the window on a hardware keyboard.
///
/// `onExitCommand` is the platform hook for it, but it is declared for macOS and
/// tvOS only; the iOS branch uses the iOS 17 key handler instead. That handler
/// fires only while the window holds keyboard focus, and this view deliberately
/// never asks for focus — a reminder must not pull focus away from the quick-add
/// field — so on iPad it stays out of the way, which is exactly the harmless
/// behaviour this needs.
private struct HardwareEscape: ViewModifier {
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onExitCommand(perform: action)
        #else
        content.onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }
}
