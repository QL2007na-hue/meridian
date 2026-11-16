//
//  ServerPanel.swift
//  Meridian — the server face of the app. OWNER: agenda/sync engineer.
//
//  This panel exists so that "is it syncing?" is answerable at a glance without
//  opening settings: state, address, revision, count, and how long ago. The one
//  control it owns is a manual refresh — everything else is a fact.
//

import Foundation
import SwiftUI

struct ServerPanel: View {
    @EnvironmentObject private var model: AppModel

    private var isSyncing: Bool { model.syncPhase == .syncing }
    private var isConfigured: Bool { model.config.isConfigured }

    var body: some View {
        MeridianCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                table
                    .padding(.top, Space.l)
                errorLine
                    .padding(.top, Space.s)
                Spacer(minLength: Space.m)
                syncButton
                hint
                    .padding(.top, Space.m)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s) {
            CapsLabel(text: model.config.autoSync ? "自动同步" : "手动同步")
            Spacer(minLength: Space.s)
        }
    }

    // MARK: - Facts

    private var table: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            KeyValueRow(label: "状态") {
                HStack(spacing: Space.xs) {
                    StatusDot(color: dotColor, pulsing: isSyncing)
                    Text(model.syncPhase.title)
                        .font(Typeface.body)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            KeyValueRow(label: "地址") { value(addressText) }
            KeyValueRow(label: "版本") { value(revText) }
            KeyValueRow(label: "任务") { value("\(model.tasks.count)") }
            KeyValueRow(label: "同步") {
                // Re-evaluated every few seconds so "23 秒前" stays true.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    value(lastSyncText(now: context.date))
                }
            }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let detail = model.syncDetail, !detail.isEmpty {
            Text(detail)
                .font(Typeface.caption)
                .foregroundStyle(Palette.ember)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if case let .failed(message) = model.syncPhase, !message.isEmpty {
            Text(message)
                .font(Typeface.caption)
                .foregroundStyle(Palette.ember)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Action

    private var syncButton: some View {
        Button {
            Haptics.tap()
            model.syncNow()
        } label: {
            HStack(spacing: Space.s) {
                StatusDot(color: isSyncing ? Palette.ember : Palette.inkTertiary, pulsing: isSyncing)
                Text(isSyncing ? "同步中" : "立即同步")
                    .font(Typeface.caption)
                    .tracking(0.6)
                    .foregroundStyle(isConfigured ? Palette.ink : Palette.inkTertiary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, Space.m)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Surface.sunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
            )
        }
        .buttonStyle(PressableStyle())
        .disabled(isSyncing || !isConfigured)
        .opacity(isConfigured ? 1 : 0.5)
    }

    // MARK: - Footer

    @ViewBuilder
    private var hint: some View {
        Group {
            if !isConfigured {
                Text("在设置里填写服务器地址")
            } else if case .offline = model.syncPhase {
                Text("离线 · 改动会在连上后自动同步")
            } else if !model.config.autoSync {
                Text("自动同步已关闭")
            } else {
                Text("每 \(Int(model.config.syncInterval)) 秒轮询一次")
            }
        }
        .font(Typeface.micro)
        .tracking(0.9)
        .foregroundStyle(Palette.inkQuaternary)
        .lineLimit(1)
    }

    // MARK: - Derived text

    private var dotColor: Color {
        switch model.syncPhase {
        case .live, .polling: return Palette.inkSecondary
        case .syncing: return Palette.ember
        case .failed: return Palette.ember
        case .offline, .idle: return Palette.inkQuaternary
        }
    }

    private var addressText: String {
        guard let url = model.config.endpoint else { return "未配置" }
        if let host = url.host, let port = url.port {
            return "\(host):\(port)"
        }
        return url.host ?? model.config.baseURL
    }

    private var revText: String {
        guard let rev = model.runtime.lastRev else { return "—" }
        return "rev \(rev)"
    }

    private func lastSyncText(now: Date) -> String {
        guard let synced = model.lastSyncedAt else { return "—" }
        return AgendaFormat.relative(synced, now: now)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Typeface.digit(11))
            .foregroundStyle(Palette.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
