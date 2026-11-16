//
//  Background.swift
//  Meridian — the six backdrops, and the value bag that drives them.
//
//  The stage and the settings preview must never drift apart, so both render
//  through `BackgroundLayer`: plain values in, one static view out. Nothing here
//  reads AppModel — that keeps the layer deterministic and lets SettingsSheet
//  show the exact pixels the stage will show, without a second copy of the
//  drawing code to keep in sync.
//

import SwiftUI

// MARK: - Spec

/// Everything a backdrop needs, as plain values. `phase` exists only for the
/// aurora's 14-second breath; every other style ignores it, which is also the
/// reason no style except aurora may animate.
struct BackgroundSpec {
    var skin: ClockSkin
    var style: AppSettings.BackgroundStyle
    /// 0 = barely there, 1 = the gradient is the point.
    var intensity: Double
    /// Hue rotation of the whole room, in turns (-0.5...0.5).
    var hueShift: Double
    /// 0...1 breathing phase. Callers that are not animating pass a still value.
    var phase: Double

    init(
        settings: AppSettings,
        style: AppSettings.BackgroundStyle? = nil,
        phase: Double = 0.5
    ) {
        self.skin = settings.skin
        self.style = style ?? settings.background
        self.intensity = settings.backgroundIntensity
        self.hueShift = settings.backgroundHueShift
        self.phase = phase
    }

    var clampedIntensity: Double { max(0, min(1, intensity)) }
    var clampedPhase: Double { max(0, min(1, phase)) }
    var hueDegrees: Double { hueShift * 360 }
}

// MARK: - Layer

/// A static backdrop. The only motion is the aurora's breath, and even that is
/// an opacity change handed in by `AmbientBackground`; there is no timeline in
/// this view, so nothing repaints at 1 Hz behind the clock.
struct BackgroundLayer: View {
    let spec: BackgroundSpec

    private var intensity: Double { spec.clampedIntensity }

    /// The canvas with the global hue offset applied. The skin owns the colour;
    /// the background only decides where it goes.
    private var canvas: RGB {
        spec.skin.canvas.hueShifted(degrees: spec.hueDegrees)
    }

    private var canvasColor: Color { canvas.color }

    private func tone(_ rgb: RGB) -> Color {
        rgb.hueShifted(degrees: spec.hueDegrees).color
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                canvasColor
                backdrop(size: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    // MARK: Styles

    @ViewBuilder
    private func backdrop(size: CGSize) -> some View {
        switch spec.style {
        case .graphite: graphite(size)
        case .aurora: aurora(size)
        case .vignette: vignette(size)
        case .gradient: gradient(size)
        case .grid: grid(size)
        case .flat: EmptyView()
        }
    }

    /// The original wash, kept as the default: one warm pool behind the time, one
    /// cold counterweight on the panel side, and a hairline horizon that gives
    /// the composition a floor.
    private func graphite(_ size: CGSize) -> some View {
        let radius = max(size.width, size.height)
        let glow = tone(spec.skin.glow)

        return ZStack {
            RadialGradient(
                colors: [
                    glow.opacity(0.10 * intensity),
                    glow.opacity(0.02 * intensity),
                    .clear
                ],
                center: UnitPoint(x: 0.34, y: 0.46),
                startRadius: 0,
                endRadius: radius * 0.72
            )
            .blendMode(.plusLighter)

            RadialGradient(
                colors: [Palette.coolDeep.opacity(0.18 * intensity), .clear],
                center: UnitPoint(x: 1.0, y: 0.10),
                startRadius: 0,
                endRadius: radius * 0.45
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, Palette.hairlineStrong, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: Metrics.hairline)
                .padding(.bottom, size.height * 0.135)
                .opacity(0.35 + 0.4 * intensity)
            }
        }
    }

    /// Two large, cool-leaning glows. The breath is an opacity trade between
    /// them (one swells while the other recedes) so the room moves without any
    /// colour stop animating — colour interpolation in gradients is not smooth
    /// on older iPads, opacity always is.
    private func aurora(_ size: CGSize) -> some View {
        let radius = max(size.width, size.height)
        let phase = spec.clampedPhase
        let glow = tone(spec.skin.glow)
        let accent = tone(spec.skin.accent)

        return ZStack {
            RadialGradient(
                colors: [
                    glow.opacity(0.20 * intensity),
                    glow.opacity(0.05 * intensity),
                    .clear
                ],
                center: UnitPoint(x: 0.28, y: 0.30),
                startRadius: 0,
                endRadius: radius * 0.95
            )
            .blendMode(.plusLighter)
            .opacity(0.72 + 0.28 * phase)

            RadialGradient(
                colors: [
                    accent.opacity(0.13 * intensity),
                    Palette.coolDeep.opacity(0.26 * intensity),
                    .clear
                ],
                center: UnitPoint(x: 0.74, y: 0.74),
                startRadius: 0,
                endRadius: radius * 0.85
            )
            .opacity(1.0 - 0.20 * phase)
        }
    }

    /// The glow inverted: bright at the centre, falling to a corner darker than
    /// the canvas. This is the one style that makes the numerals look lit.
    private func vignette(_ size: CGSize) -> some View {
        let radius = max(size.width, size.height)

        return RadialGradient(
            colors: [
                canvas.lightened(0.10 * intensity).color,
                canvasColor,
                canvas.darkened(0.85 * intensity).color
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius * 0.85
        )
    }

    /// One vertical gradient: canvas at the top, the same canvas lifted 8% at the
    /// bottom. Intensity walks the second stop back toward the first, so 0 is a
    /// flat canvas and 1 is the full 8%.
    private func gradient(_ size: CGSize) -> some View {
        let lifted = canvas.lightened(0.08)
        let end = canvas.mixed(with: lifted, amount: intensity)

        return LinearGradient(
            colors: [canvasColor, end.color],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Engineering paper: 1px lines every 64pt, capped at 5% opacity so the grid
    /// reads as texture at arm's length and disappears at three metres. Drawn in
    /// one Canvas pass rather than 60 Views — a static layer is the whole point.
    private func grid(_ size: CGSize) -> some View {
        let line = tone(spec.skin.accent)
        let opacity = min(0.05, 0.055 * intensity)

        return Canvas { context, canvasSize in
            guard opacity > 0 else { return }
            let step = Space.huge
            var path = Path()

            var x = step
            while x < canvasSize.width {
                path.addRect(CGRect(x: x, y: 0, width: Metrics.hairline, height: canvasSize.height))
                x += step
            }
            var y = step
            while y < canvasSize.height {
                path.addRect(CGRect(x: 0, y: y, width: canvasSize.width, height: Metrics.hairline))
                y += step
            }
            context.fill(path, with: .color(line.opacity(opacity)))
        }
    }
}
