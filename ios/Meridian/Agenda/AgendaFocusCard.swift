//
//  AgendaFocusCard.swift
//  Meridian — the agenda, pulled forward over an immersive clock.
//
//  The focused stage keeps the clock in place and slides a single card in from
//  the right, dimming the numerals instead of shrinking the layout. That matters:
//  the numerals are sized from the available width, so narrowing the stage would
//  make the font jump. Dimming + a 1.5% pull-back reads as "focus" while the
//  time stays exactly where the user left it.
//

import SwiftUI

struct AgendaFocusCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: Metrics.cardGap) {
            header
            AgendaPanel()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        )
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            CapsLabel(text: "今日 · 聚焦", accent: false)
            Spacer(minLength: Space.s)
            Button {
                model.closeFocus()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.wash(0.04)))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: Metrics.hairline))
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("关闭聚焦")
        }
        .padding(.horizontal, Space.xs)
    }
}
