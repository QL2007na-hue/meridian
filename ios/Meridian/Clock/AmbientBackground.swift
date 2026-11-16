//
//  AmbientBackground.swift
//  Meridian — the room the clock sits in.
//
//  Six styles live in Core/Background.swift; this view only decides which values
//  feed them, and owns the one animation the room is allowed to have: the
//  aurora's 14-second breath. Everything here is a static layer, so a clock left
//  on for a week does not repaint its whole background every second.
//

import SwiftUI

struct AmbientBackground: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0...1. Ignored by every style except aurora, which trades it between its
    /// two glows. Kept at the midpoint when still so the preview and the stage
    /// agree on a representative frame.
    @State private var phase: Double = 0.5

    var body: some View {
        BackgroundLayer(spec: BackgroundSpec(settings: model.settings, phase: phase))
            .ignoresSafeArea()
            .onAppear { restartBreathing() }
            // Switching styles restarts the breath: a graphite or grid backdrop
            // must not keep an animation running behind a still image.
            .onChange(of: model.settings.background) { _, _ in restartBreathing() }
            .onChange(of: reduceMotion) { _, _ in restartBreathing() }
    }

    private func restartBreathing() {
        phase = 0.5
        guard model.settings.background == .aurora, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }
}
