//
//  TaskRow.swift
//  Meridian — one agenda line. OWNER: agenda/sync engineer.
//
//  A row is one tap target: tapping anywhere toggles completion. Checking things
//  off is the most frequent interaction on this screen, so it must cost one tap
//  and never a precisely aimed one. The checkbox is therefore an indicator, not
//  a button.
//

import Foundation
import SwiftUI

struct TaskRow: View {
    let task: AgendaTask
    /// The panel draws the separators, because only it knows which row is last.
    var showsHairline: Bool = true

    @EnvironmentObject private var model: AppModel
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: 0) {
            row
            if showsHairline { Hairline() }
        }
    }

    private var row: some View {
        HStack(spacing: Space.m) {
            stateMark

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(task.title)
                    .font(Typeface.body)
                    .foregroundStyle(task.isDone ? Palette.inkTertiary : Palette.ink)
                    .strikethrough(task.isDone, pattern: .solid, color: Palette.inkQuaternary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !task.note.isEmpty {
                    Text(task.note)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkQuaternary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Space.s)

            if let due = task.due {
                Text(AgendaFormat.clock(due))
                    .font(Typeface.digit(11))
                    .foregroundStyle(Palette.inkTertiary)
            }

            priorityBar
        }
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.settle) { model.toggle(task) }
        }
        .contextMenu {
            Button {
                var moved = task
                moved.day = DayKey.tomorrow()
                withAnimation(Motion.settle) { model.update(moved) }
            } label: {
                Label("改为明天", systemImage: "calendar")
            }
            Button(role: .destructive) {
                withAnimation(Motion.settle) { model.delete(task) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(task.isDone ? "已完成" : "未完成"))
    }

    // MARK: - Parts

    /// 20pt ring → ember disc. Crossfaded, never staged: the check never appears
    /// before the disc under it, or the tick looks pasted on.
    private var stateMark: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.hairlineStrong, lineWidth: Metrics.hairline)
                .opacity(task.isDone ? 0 : 1)
            Circle()
                .fill(skin.accentColor)
                .opacity(task.isDone ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.canvas)
                .scaleEffect(task.isDone ? 1 : 0.5)
                .opacity(task.isDone ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .animation(Motion.snap, value: task.isDone)
    }

    /// Absence is the signal for a normal task, so nothing is drawn for it —
    /// a third grey bar would only add noise to a list of mostly-normal items.
    @ViewBuilder
    private var priorityBar: some View {
        switch task.priority {
        case .critical:
            bar(skin.accentColor)
        case .notable:
            bar(skin.accentColor.opacity(0.45))
        case .normal:
            EmptyView()
        }
    }

    private func bar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 3, height: 14)
    }
}

// MARK: - Formatting

/// The three strings this panel column needs, in one place so "11:05" and
/// "23 秒前" are spelled the same way everywhere in the strip.
///
/// Formatters are shared statics: only ever read on the main actor from a view,
/// and building a DateFormatter per row per second would be the one measurably
/// expensive thing in these panels.
enum AgendaFormat {

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEE"
        return formatter
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "11月15日 · 周六"
    static func dayLine(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    /// `mm:ss`, widened to `h:mm:ss` past the hour — "213:14" reads as broken.
    static func countdown(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        guard hours > 0 else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    /// "23 秒前". Rounded down on purpose: "1 分钟前" arriving at 61s is more
    /// honest than a jump from "59 秒前".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}
