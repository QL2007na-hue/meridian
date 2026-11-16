//
//  StatusStrip.swift
//  Meridian — the one line of small print under the time.
//
//  Answers, in order: is the server reachable, how much of today is done, and
//  when is the next thing. Everything else belongs in a panel.
//

import SwiftUI
import UIKit

struct StatusStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: Space.l) {
                connectionCluster
                separator
                progressCluster
                if let next = model.nextTask, let due = next.due {
                    separator
                    Text("下一个 \(Self.timeText(due)) · \(next.title)")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let banner = model.banner {
                    Text(banner)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.ember)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: model.banner)
            .frame(height: 16)
        }
    }

    private var connectionCluster: some View {
        HStack(spacing: 6) {
            StatusDot(color: dotColor, pulsing: model.syncPhase == .syncing)
            Text(stamp)
                .font(Typeface.micro)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var progressCluster: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.hairline, lineWidth: 1)
                Circle()
                    .trim(from: 0, to: model.completionToday)
                    .stroke(Palette.ember.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)

            Text("今日 \(model.doneTodayCount)/\(model.todayTasks.count)")
                .font(Typeface.micro)
                .tracking(1.0)
                .foregroundStyle(Palette.inkTertiary)
                .monospacedDigit()
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.hairlineStrong)
            .frame(width: 1, height: 9)
    }

    private var dotColor: Color {
        switch model.syncPhase {
        case .live, .polling: return Palette.inkSecondary
        case .syncing: return Palette.ember
        case .offline, .failed: return Palette.inkQuaternary
        default: return Palette.inkQuaternary
        }
    }

    private var stamp: String {
        switch model.syncPhase {
        case .idle: return model.config.isConfigured ? "待连接" : "本地模式"
        case .syncing: return "同步中"
        case .live: return "在线"
        case .polling: return "在线"
        case .offline: return "离线 · 已缓存"
        case .failed: return "连接异常"
        }
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
