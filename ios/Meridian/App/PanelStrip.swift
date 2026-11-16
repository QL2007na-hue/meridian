//
//  PanelStrip.swift
//  Meridian — the utility column.
//
//  One card at a time, full height, plus a switcher at the bottom. A strip of
//  five cards would be a dashboard; one card is a glance. The switcher is the
//  only chrome in the app that looks like a control.
//

import SwiftUI

struct PanelStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: Metrics.cardGap) {
            PanelHeader()
            panelBody
                .frame(maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
            PanelSwitcher()
        }
        .animation(Motion.settle, value: model.activePanel)
    }

    @ViewBuilder
    private var panelBody: some View {
        switch model.activePanel {
        case .agenda:
            AgendaPanel()
        case .next:
            NextPanel()
        case .focus:
            FocusPanel()
        case .world:
            WorldPanel()
        case .server:
            ServerPanel()
        }
    }
}

// MARK: - Header

/// Panel name, honest sync state, and the one door out of the clock. It lives
/// here rather than floating over the stage so it can never sit on a numeral.
private struct PanelHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Space.s) {
            CapsLabel(text: model.activePanel.title, accent: false)
            Spacer(minLength: Space.s)
            SyncBadge()
            settingsButton
        }
        .padding(.horizontal, Space.xs)
    }

    private var settingsButton: some View {
        Button {
            Haptics.tap()
            model.showingSettings = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.wash(0.03)))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel("设置")
    }
}

/// The smallest possible honest status: a dot, and a word. No spinner unless
/// something is actually in flight.
struct SyncBadge: View {
    @EnvironmentObject private var model: AppModel

    private var dotColor: Color {
        switch model.syncPhase {
        case .live, .polling: return Palette.inkSecondary
        case .syncing: return Palette.ember
        case .failed: return Palette.ember
        default: return Palette.inkQuaternary
        }
    }

    private var label: String {
        switch model.syncPhase {
        case .idle: return model.config.isConfigured ? "待连接" : "未配置"
        case .syncing: return "同步中"
        case .live: return "在线"
        case .polling: return "在线"
        case .offline: return "离线"
        case .failed: return "异常"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: dotColor, pulsing: model.syncPhase == .syncing)
            Text(label)
                .font(Typeface.micro)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.inkTertiary)
        }
    }
}

// MARK: - Switcher

private struct PanelSwitcher: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelID.allCases) { panel in
                Button {
                    guard model.activePanel != panel else { return }
                    Haptics.tap()
                    withAnimation(Motion.settle) { model.activePanel = panel }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: panel.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        if model.activePanel == panel {
                            Text(panel.title)
                                .font(Typeface.micro)
                                .tracking(1.0)
                        }
                    }
                    .foregroundStyle(model.activePanel == panel ? Palette.ink : Palette.inkTertiary)
                    .padding(.horizontal, model.activePanel == panel ? 12 : 10)
                    .frame(height: 32)
                    .background(
                        Capsule()
                            .fill(model.activePanel == panel ? Palette.wash(0.075) : .clear)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            model.activePanel == panel ? Palette.hairlineStrong : .clear,
                            lineWidth: Metrics.hairline
                        )
                    )
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .accessibilityLabel(panel.title)
            }
        }
        .padding(Space.xs)
        .background(
            Capsule().fill(Palette.wash(0.028))
        )
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
        .frame(maxWidth: .infinity)
    }
}
