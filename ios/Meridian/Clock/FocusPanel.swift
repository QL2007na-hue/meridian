//
//  FocusPanel.swift
//  Meridian — one focus block, on the panel column.
//
//  The card answers three questions and stops: how much is left (a ring, because
//  a countdown is a circle by nature), until when (one line), and how do I start
//  another (three presets). No big pictogram in the empty state — an empty focus
//  card is not an illustration, it is a slot waiting to be filled.
//
//  The one-second timeline is scoped to the dial so the presets below it never
//  rebuild while a session runs.
//

import Foundation
import SwiftUI

/// One focus block on the panel column: a ring, the countdown inside it, and the
/// three durations worth pressing. States the elapsed fraction as "left" because
/// that is the number a person actually wants on a wall.
struct FocusPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.skin) private var skin

    /// Guards the finish call: the countdown hits zero once, but the timeline
    /// keeps ticking until `model.focus` is cleared.
    @State private var hasFinished = false

    private static let presets = [25, 45, 90]

    var body: some View {
        MeridianCard(padding: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                header

                if let session = model.focus {
                    dial(session)
                        .onAppear { finishIfExpired(session) }
                } else {
                    EmptyNote(text: "没有进行中的专注")
                }

                Spacer(minLength: Space.m)

                presetsRow
            }
        }
        .onChange(of: model.focus?.startedAt) { _, _ in
            hasFinished = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if model.focus != nil {
                CapsLabel(text: "进行中", accent: true)
            } else {
                CapsLabel(text: "未开始")
            }
            Spacer(minLength: Space.s)
        }
    }

    // MARK: Running session

    private func dial(_ session: FocusSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = session.remaining(at: context.date)
            let total = Double(max(1, session.minutes)) * 60
            let fraction = remaining / total

            HStack(spacing: Space.l) {
                ZStack {
                    RingGauge(progress: fraction, lineWidth: 3, tint: skin.accentColor)
                        .frame(width: Space.huge, height: Space.huge)
                    Text(Self.mmss(remaining))
                        .font(Typeface.digit(13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(session.label)
                        .font(Typeface.bodyMedium)
                        .foregroundStyle(Palette.inkSecondary)
                    Text("至 \(Self.clockText(session.endsAt))")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkTertiary)
                    Button {
                        model.cancelFocus()
                    } label: {
                        Text("放弃")
                            .font(Typeface.micro)
                            .tracking(1.2)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .accessibilityLabel("放弃本次专注")
                }

                Spacer(minLength: 0)
            }
            .onChange(of: remaining <= 0) { _, expired in
                guard expired else { return }
                finishIfExpired(session)
            }
        }
    }

    /// Completes the block exactly once. Also covers the relaunch case, where a
    /// session expired while the app was closed and no value ever changed.
    private func finishIfExpired(_ session: FocusSession) {
        guard model.focus?.startedAt == session.startedAt else { return }
        guard session.remaining(at: Date()) <= 0 else { return }
        guard !hasFinished else { return }
        hasFinished = true
        model.finishFocus()
    }

    // MARK: Presets

    private var presetsRow: some View {
        HStack(spacing: Space.xs) {
            ForEach(Self.presets, id: \.self) { minutes in
                let active = model.focus?.minutes == minutes

                Button {
                    model.startFocus(minutes: minutes)
                } label: {
                    Text("\(minutes) 分")
                        .font(Typeface.digit(12, weight: .medium))
                        .foregroundStyle(active ? skin.accentColor : Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Space.xxl)
                        .background(
                            Capsule().fill(active ? skin.accentColor.opacity(0.16) : Palette.canvasDeck)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                active ? skin.accentColor.opacity(0.35) : Palette.hairline,
                                lineWidth: Metrics.hairline
                            )
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .accessibilityLabel("专注 \(minutes) 分钟")
            }
        }
    }

    // MARK: Formatting

    private static func mmss(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = clockFormatter
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
