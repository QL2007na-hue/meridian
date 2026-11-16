//
//  ClockStage.swift
//  Meridian — the clock. The only thing on this screen allowed to be large.
//
//  One vertical composition: a micro rail at the top (weekday, date, lunar,
//  zone), the numerals in the middle, a micro rail at the bottom with the day's
//  progress. The three clock styles rearrange these same parts instead of
//  building three screens, so there is exactly one layout to keep correct.
//
//  Refresh rates are deliberately separated:
//    · everyMinute          — the rails, the date and the numerals
//    · periodic(by: 1)      — the seconds digits and the seconds ring, nothing else
//    · periodic(by: 1800)   — the anti-burn-in drift
//  Nothing repaints at 1 Hz except the two glyph-sized views that must.
//

import Foundation
import SwiftUI

/// The stage: two rails, the numerals, and the three ways they can be arranged.
/// It owns the only per-minute timeline in the app; anything finer-grained lives
/// inside the small views it composes.
struct ClockStage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            BurnInDrift(enabled: model.settings.burnInDrift, preview: model.burnInPreview) {
                TimelineView(.everyMinute) { context in
                    stage(now: context.date, size: proxy.size)
                        .opacity(stageOpacity(at: context.date))
                        .animation(reduceMotion ? nil : Motion.fade, value: model.ambientLevel)
                        .animation(reduceMotion ? nil : Motion.fade, value: model.settings.ambientAdaptive)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // Deliberately no scale on immersive entry: the stage is already as
            // wide as the glass, so 1.03 pushed the rail's right end (lunar +
            // zone) past the edge and the date line lost its tail. The panel
            // leaving is enough of a change; the numerals do not need to grow.
            //
            // Focus is the opposite direction — a 1.5% pull-back and a dim, which
            // cannot clip because it shrinks — so the agenda can come forward
            // without the numerals being resized by the narrower layout.
            .opacity(model.agendaFocus ? 0.42 : 1)
            .scaleEffect(model.agendaFocus ? 0.985 : 1, anchor: .leading)
            .animation(reduceMotion ? nil : Motion.settle, value: model.agendaFocus)
            .animation(reduceMotion ? nil : Motion.settle, value: model.immersive)
            // The stage owns its own blank space, so a tap on the glass walks the
            // stages back towards the clock. Panel interactions are siblings, so
            // they never see this gesture.
            .contentShape(Rectangle())
            .onTapGesture { model.advanceStage() }
        }
    }

    // MARK: Composition

    private func stage(now: Date, size: CGSize) -> some View {
        let inset = Metrics.stageInset
        // Symmetric: the numerals are centred in the stage now, so an asymmetric
        // inset would shift the optical centre towards the panel side.
        let usableWidth = max(0, size.width - inset * 2)
        let usableHeight = max(0, size.height - Space.xxl)
        // Width and height both bound the numerals; whichever is tighter wins,
        // so the same code is correct on an 11" iPad and on an iPhone.
        let timeSize = min(usableWidth * 0.205, usableHeight * 0.46)

        return VStack(alignment: .leading, spacing: 0) {
            topRail(now: now)
            Spacer(minLength: Space.l)
            timeRow(now: now, timeSize: timeSize)
            Spacer(minLength: Space.l)
            bottomRail(now: now)
        }
        .padding(.horizontal, inset)
        // Keeps the day-progress rule clear of the status strip sharing the
        // bottom-left of the screen.
        .padding(.bottom, Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func topRail(now: Date) -> some View {
        let settings = model.settings
        let faded = settings.clockStyle == .minimal

        return HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            if settings.clockStyle == .inline {
                Spacer(minLength: 0)
                Text(DateRibbon.timeZoneLabel(for: now)).microLabel()
            } else {
                DateRibbon(
                    date: now,
                    style: .stacked,
                    size: 11,
                    showsYear: false,
                    showsLunar: settings.showLunar,
                    showsTimeZone: true
                )
            }
        }
        .opacity(faded ? 0 : 1)
        .animation(reduceMotion ? nil : Motion.fade, value: faded)
        .allowsHitTesting(!faded)
    }

    private func timeRow(now: Date, timeSize: CGFloat) -> some View {
        let settings = model.settings
        let skin = settings.skin

        // The time sits in the optical centre of whatever width the stage has,
        // not against the left edge: with a panel or a glance strip on the
        // right, left-aligning made the whole screen read off-balance.
        return HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Spacer(minLength: 0)

            if settings.clockStyle == .inline {
                DateRibbon(date: now, style: .inline, size: max(13, timeSize * 0.13))
            }

            TimeReadout(
                now: now,
                size: timeSize,
                use24Hour: settings.use24Hour,
                showsSeconds: settings.showSeconds,
                // Without rails there is nowhere else to put it.
                showsMeridiem: !settings.use24Hour && settings.clockStyle == .minimal,
                skin: skin
            )

            if settings.showSeconds && settings.showSecondRing && skin.ring != .none {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SecondRing(
                        second: Self.second(of: context.date),
                        diameter: ringDiameter(for: timeSize),
                        accent: skin.accentColor,
                        face: skin.ring
                    )
                }
                // A ring has no text baseline of its own; hang it a little above
                // the numerals' baseline so the composition reads as one line.
                .alignmentGuide(.firstTextBaseline) { dimension in dimension.height * 0.58 }
            }

            Spacer(minLength: 0)
        }
    }

    private func bottomRail(now: Date) -> some View {
        let settings = model.settings
        let faded = settings.clockStyle == .minimal
        let progress = Self.dayProgress(now)

        var parts: [String] = []
        if !settings.use24Hour {
            parts.append(TimeReadout.meridiemText(now))
        }
        parts.append("第 \(Self.dayOfYear(now)) 天")

        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(parts.joined(separator: " · ")).microLabel()
                Spacer(minLength: Space.m)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(Typeface.digit(10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Palette.inkQuaternary)
            }
            progressRule(progress)
        }
        .opacity(faded ? 0 : 1)
        .animation(reduceMotion ? nil : Motion.fade, value: faded)
    }

    /// How much of today is gone, as a hairline. The one place the accent is
    /// allowed to be quiet: half strength, one pixel, no glow.
    private func progressRule(_ progress: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Palette.hairline)
            Rectangle()
                .fill(model.settings.skin.accentColor.opacity(0.5))
                .scaleEffect(x: max(0.001, min(1, progress)), anchor: .leading)
        }
        .frame(height: Metrics.hairline)
    }

    // MARK: Derived values

    private func ringDiameter(for timeSize: CGFloat) -> CGFloat {
        min(56, max(44, timeSize * 0.36))
    }

    private func isDimmed(at date: Date) -> Bool {
        // Ambient adaptation wins when it is available: the sensor knows the
        // room, the clock only knows the hour.
        if model.settings.ambientAdaptive, model.ambientLevel > 0.001 {
            return model.ambientLevel < 0.42
        }
        let settings = model.settings
        guard settings.dimAtNight else { return false }

        let hour = Calendar.current.component(.hour, from: date)
        let start = settings.nightStartHour
        let end = settings.nightEndHour
        if start == end { return false }
        // A night window is allowed to cross midnight; an hour either side of it
        // has to be handled separately or 23:30 would read as daytime.
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    /// Interface brightness, 0.35...1. With ambient adaptation on, this follows
    /// the room but never drops below a floor — "dim" has to stay legible, which
    /// is the whole reason the floor exists.
    private func stageOpacity(at date: Date) -> Double {
        if model.settings.ambientAdaptive, model.ambientLevel > 0.001 {
            let ambient = min(1, max(0, model.ambientLevel))
            return 0.55 + ambient * 0.45
        }
        return isDimmed(at: date) ? 0.62 : 1
    }

    private static func second(of date: Date) -> Int {
        Calendar.current.component(.second, from: date)
    }

    private static func dayProgress(_ date: Date) -> Double {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }

    private static func dayOfYear(_ date: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

// MARK: - Anti burn-in

/// Walks the whole composition one point around a 2×2 square, one corner every
/// half hour, over three seconds. Derived from the wall clock rather than from a
/// counter, so relaunching the app does not restart the cycle and leave the same
/// pixels lit. Invisible by design: the point is that no pixel is permanent.
///
/// Shared with the immersive glance strip — anything that sits on the glass for
/// weeks drifts together, or the strip would leave a ghost of its own.
struct BurnInDrift<Content: View>: View {
    let enabled: Bool
    /// Demo mode: 8pt every two seconds instead of 1pt every half hour, so the
    /// user can see that the mechanism is actually running. Never on by default.
    var preview: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Explicit: a private stored wrapper would make the memberwise initialiser
    // private, and the stage above it lives outside this declaration.
    init(enabled: Bool, preview: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.enabled = enabled
        self.preview = preview
        self.content = content
    }

    var body: some View {
        if enabled && preview {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                content()
                    .offset(Self.cornerOffset(at: context.date, amplitude: 8))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.4), value: context.date)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1800)) { context in
                // Reduced motion wins: a one-point jump every half hour would be a
                // twitch, so the drift is off rather than un-animated.
                let offset = (enabled && !reduceMotion) ? Self.cornerOffset(at: context.date, amplitude: 1) : .zero
                content()
                    .offset(x: offset.width, y: offset.height)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 3), value: offset)
            }
        }
    }

    private static func cornerOffset(at date: Date, amplitude: CGFloat) -> CGSize {
        let step = Int(date.timeIntervalSince1970 / (amplitude > 1 ? 2 : 1800))
        switch ((step % 4) + 4) % 4 {
        case 1: return CGSize(width: amplitude, height: 0)
        case 2: return CGSize(width: amplitude, height: amplitude)
        case 3: return CGSize(width: 0, height: amplitude)
        default: return .zero
        }
    }
}
