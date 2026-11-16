//
//  NextPanel.swift
//  Meridian — what comes after now. OWNER: agenda/sync engineer.
//
//  The one panel that is allowed to move every second, and only while it has
//  something to count down to: a clock that ticks for no reason is noise.
//

import Foundation
import SwiftUI

struct NextPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MeridianCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if model.nextTask != nil {
                    // Seconds only matter when there is a deadline on screen.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        stage(now: context.date)
                    }
                } else {
                    stage(now: Date())
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }

    // MARK: - Composition

    @ViewBuilder
    private func stage(now: Date) -> some View {
        let upcoming = upcomingTasks(now: now)

        VStack(alignment: .leading, spacing: 0) {
            if let next = upcoming.first, let due = next.due {
                countdownBlock(task: next, due: due, now: now)
                if upcoming.count > 1 {
                    followingBlock(Array(upcoming.dropFirst().prefix(3)))
                }
            } else {
                idleBlock
            }
            Spacer(minLength: 0)
        }
    }

    /// Open tasks with a due time still in the future, in the canonical order.
    private func upcomingTasks(now: Date) -> [AgendaTask] {
        model.openTodayTasks.filter { task in
            guard let due = task.due else { return false }
            return due > now
        }
    }

    // MARK: - Blocks

    private func countdownBlock(task: AgendaTask, due: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(AgendaFormat.countdown(due.timeIntervalSince(now)))
                    .font(Typeface.clock(46))
                    .foregroundStyle(Palette.ink)
                Text("后")
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(task.title)
                    .font(Typeface.headline)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2)
                Spacer(minLength: Space.xs)
                Text(AgendaFormat.clock(due))
                    .font(Typeface.digit(11))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.top, Space.m)
    }

    private func followingBlock(_ tasks: [AgendaTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
                .padding(.top, Space.m)
            ForEach(tasks) { task in
                HStack(spacing: Space.m) {
                    Text(task.due.map(AgendaFormat.clock) ?? "—")
                        .font(Typeface.digit(11))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(width: 40, alignment: .leading)
                    Text(task.title)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
                if task.id != tasks.last?.id { Hairline() }
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleBlock: some View {
        if model.todayTasks.isEmpty {
            EmptyNote(text: "今天没有安排")
                .padding(.top, Space.m)
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                    Text("\(Int((model.completionToday * 100).rounded()))")
                        .font(Typeface.title)
                        .foregroundStyle(Palette.inkSecondary)
                    Text("%")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
                Text(idleNote)
                    .font(Typeface.body)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.top, Space.s)
        }
    }

    private var idleNote: String {
        if model.openTodayTasks.isEmpty { return "今天没有剩余安排" }
        return "还有 \(model.openTodayTasks.count) 件待办"
    }
}
