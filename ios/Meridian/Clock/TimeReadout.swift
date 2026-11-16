//
//  TimeReadout.swift
//  Meridian — HH:MM, with the seconds beside it.
//
//  The numerals are the whole app, so this view is deliberately plain: three
//  texts, one of which breathes. It reads its instant from the caller's minute
//  timeline instead of owning a clock, which is what keeps a 300pt numeral from
//  being rebuilt sixty times a second.
//
//  Only the digit groups that actually change get a numeric-text transition, so
//  at 09:41 the hour stays perfectly still while the minute rolls.
//

import Foundation
import SwiftUI

/// HH:MM with the seconds beside it. Owns no clock of its own — the stage hands
/// it an instant once a minute — so the numerals cannot be caught repainting at
/// a rate nothing on screen needs.
struct TimeReadout: View {
    /// The instant to render, supplied by the stage's minute timeline.
    let now: Date
    /// Point size of the hour and minute numerals, derived from the geometry by
    /// the stage. Everything else here is proportional to it.
    let size: CGFloat
    let use24Hour: Bool
    var showsSeconds: Bool = true
    /// Needed only when the rails are faded out. Every other style prints
    /// 上午/下午 in the bottom rail, and printing it twice is noise.
    var showsMeridiem: Bool = false
    /// The look of the numerals. Defaults to the graphite preset so the view
    /// still works in a preview that has no skin in its environment.
    var skin: ClockSkin = .graphite

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Written out rather than synthesised: a private `@Environment` stored
    // property would otherwise pull the memberwise initialiser down to `private`
    // and the stage could not build this view.
    init(now: Date, size: CGFloat, use24Hour: Bool, showsSeconds: Bool = true,
         showsMeridiem: Bool = false, skin: ClockSkin = .graphite) {
        self.now = now
        self.size = size
        self.use24Hour = use24Hour
        self.showsSeconds = showsSeconds
        self.showsMeridiem = showsMeridiem
        self.skin = skin
    }

    /// Negative tracking stops a light rounded face from looking spaced out at
    /// display sizes. It is proportional, so it survives any geometry.
    private var tracking: CGFloat { -size * 0.035 }
    private var secondsSize: CGFloat { max(11, size * 0.105) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                numeral(Self.hourText(now, use24Hour: use24Hour))
                BreathingColon(size: size, skin: skin)
                numeral(Self.minuteText(now))
            }

            if showsSeconds {
                // Own timeline, own refresh rate: the big numerals below this
                // line must not be touched once a second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    secondGlyph(Self.secondText(context.date))
                }
            }

            if showsMeridiem {
                Text(Self.meridiemText(now))
                    .font(Typeface.micro)
                    .tracking(1.4)
                    .foregroundStyle(skin.inkColor.opacity(0.55))
            }
        }
    }

    // MARK: Numerals

    private func numeral(_ text: String) -> some View {
        Text(text)
            .font(skin.numerals(size))
            .tracking(tracking)
            .foregroundStyle(skin.numeralStyle)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : Motion.snap, value: text)
    }

    private func secondGlyph(_ text: String) -> some View {
        Text(text)
            .font(skin.numerals(secondsSize))
            .tracking(secondsSize * 0.04)
            .foregroundStyle(skin.inkColor.opacity(0.42))
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : Motion.snap, value: text)
    }

    // MARK: Formatting

    static func hourText(_ date: Date, use24Hour: Bool) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let display = use24Hour ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        return String(format: "%02d", display)
    }

    static func minuteText(_ date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.minute, from: date))
    }

    static func secondText(_ date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.second, from: date))
    }

    static func meridiemText(_ date: Date) -> String {
        Calendar.current.component(.hour, from: date) < 12 ? "上午" : "下午"
    }
}

// MARK: - Colon

/// The colon is the only part of the numerals allowed to move: a two-second
/// breath that says the clock is running without a spinner. It is its own view
/// so the breathing animation never invalidates the hour or the minute.
private struct BreathingColon: View {
    let size: CGFloat
    let skin: ClockSkin

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded = false

    init(size: CGFloat, skin: ClockSkin = .graphite) {
        self.size = size
        self.skin = skin
    }

    var body: some View {
        Text(":")
            .font(skin.numerals(size))
            .tracking(-size * 0.035)
            .foregroundStyle(skin.numeralStyle)
            .padding(.horizontal, size * 0.008)
            .opacity(faded ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    faded = true
                }
            }
    }
}
