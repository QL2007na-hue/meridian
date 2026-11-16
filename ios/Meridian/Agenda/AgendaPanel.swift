//
//  AgendaPanel.swift
//  Meridian — today's list. OWNER: agenda/sync engineer.
//
//  Three bands in one card: a header that answers "how much of today is left",
//  the list that scrolls under it, and a single input line pinned to the bottom.
//  The list is the only flexible band, which is what keeps the card's edges
//  from moving as rows come and go.
//

import Foundation
import SwiftUI

struct AgendaPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.skin) private var skin

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var tasks: [AgendaTask] { model.todayTasks }

    var body: some View {
        MeridianCard(padding: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                list
                QuickAddBar(text: $draft, isFocused: $inputFocused) { commit() }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                // The panel's own name lives in the strip header above us; this
                // line is about today, not about the panel.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(AgendaFormat.dayLine(context.date))
                        .font(Typeface.bodyMedium)
                        .foregroundStyle(Palette.ink)
                }
                Text("\(tasks.count) 件 · 已完成 \(model.doneTodayCount)")
                    .font(Typeface.micro)
                    .tracking(1.4)
                    .foregroundStyle(Palette.inkQuaternary)
            }

            Spacer(minLength: Space.s)

            HStack(spacing: Space.s) {
                RingGauge(progress: model.completionToday, lineWidth: 2, tint: skin.accentColor)
                    .frame(width: 32, height: 32)
                Text("\(model.doneTodayCount)/\(tasks.count)")
                    .font(Typeface.digit(12, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
            }

            Button {
                inputFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.wash(0.05)))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
            }
            .buttonStyle(PressableStyle(scale: 0.92))
            .accessibilityLabel("添加待办")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if tasks.isEmpty {
            EmptyNote(text: "今天还没有安排")
                .padding(.top, Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, showsHairline: task.id != tasks.last?.id)
                    }
                }
                .padding(.trailing, Space.xxs)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Commit

    private func commit() {
        let title = draft
        draft = ""
        model.addTask(title: title)
        // Stay in the field: a second item costs one more line, not one more tap.
        inputFocused = true
    }
}
