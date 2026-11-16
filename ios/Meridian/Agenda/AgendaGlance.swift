//
//  AgendaGlance.swift
//  Meridian — the right edge of an immersive clock.
//
//  When the panel column is gone the stage used to be empty on the right, which
//  read as "unfinished" rather than "minimal". This is the answer: three lines of
//  the day, no card, no background, one hairline. It is a glance, not a panel —
//  the numerals still own the screen, and the strip exists to be tapped rather
//  than read closely.
//
//  Everything enters with a 50ms-per-row spring so the column assembles instead
//  of appearing, and the whole strip sits inside BurnInDrift like the clock.
//

import SwiftUI

struct AgendaGlance: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    private var tasks: [AgendaTask] { model.todayTasks }

    var body: some View {
        Button {
            model.focusAgenda()
        } label: {
            HStack(alignment: .top, spacing: Space.l) {
                // The divider is the only structure the strip gets: it separates
                // the time from the day without drawing a container around it.
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: Metrics.hairline)
                    .padding(.vertical, Space.s)

                VStack(alignment: .leading, spacing: Space.s) {
                    header
                    if tasks.isEmpty {
                        emptyNote
                    } else {
                        ForEach(Array(tasks.prefix(3).indices), id: \.self) { index in
                            row(tasks[index])
                                .opacity(appeared ? 1 : 0)
                                .offset(x: appeared ? 0 : 10)
                                .animation(
                                    reduceMotion ? nil : Motion.settle.delay(Double(index) * 0.055),
                                    value: appeared
                                )
                        }
                    }
                    Spacer(minLength: Space.m)
                    footer
                }
            }
            .padding(.vertical, Space.xl)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlanceButtonStyle())
        .onAppear { appeared = true }
        .accessibilityLabel("展开今日待办")
    }

    // MARK: Bands

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("今日")
                .font(Typeface.micro)
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Space.s)
            Text("\(model.doneTodayCount)/\(tasks.count)")
                .font(Typeface.digit(10, weight: .medium))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .padding(.bottom, Space.xs)
    }

    private func row(_ task: AgendaTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Circle()
                .fill(dotColor(task))
                .frame(width: 4, height: 4)
                .offset(y: -4)

            if let due = task.due {
                Text(AgendaFormat.clock(due))
                    .font(Typeface.digit(10))
                    .foregroundStyle(Palette.inkQuaternary)
                    .frame(width: 34, alignment: .leading)
            }

            Text(task.title)
                .font(Typeface.body)
                .foregroundStyle(task.isDone ? Palette.inkQuaternary : Palette.inkSecondary)
                .strikethrough(task.isDone, color: Palette.inkQuaternary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    private var emptyNote: some View {
        Text("今天没有安排")
            .font(Typeface.body)
            .foregroundStyle(Palette.inkQuaternary)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("展开")
                .font(Typeface.micro)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Palette.inkTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .padding(.top, Space.l)
    }

    private func dotColor(_ task: AgendaTask) -> Color {
        if task.isDone { return Palette.inkQuaternary }
        switch task.priority {
        case .critical: return skin.accentColor
        case .notable: return skin.accentColor.opacity(0.5)
        case .normal: return Palette.inkTertiary
        }
    }
}

// MARK: - Press feedback

/// The glass is the target: a whole-strip highlight would read as a card, so the
/// only feedback is a 2pt nudge towards the edge it will expand from.
private struct GlanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: configuration.isPressed ? 2 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}
