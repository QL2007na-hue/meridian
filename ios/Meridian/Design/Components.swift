//
//  Components.swift
//  Meridian — the small set of primitives every screen is built from.
//
//  Deliberately few: a card, a hairline, a caps label, a progress ring, a
//  status dot, a pressable row. If a screen needs something else, it should be
//  composable from these rather than a new style.
//

import SwiftUI

// MARK: - Card

/// The surface every panel sits on: a short gradient, a hairline border, a
/// light catch along the top edge, and a soft outer shadow that only exists to
/// separate it from the canvas — never to decorate.
struct MeridianCard<Content: View>: View {
    var padding: CGFloat = Space.xl
    var radius: CGFloat = Radius.card
    var tone: CardTone = .raised
    @ViewBuilder var content: () -> Content

    enum CardTone {
        case raised
        case sunken
        case clear
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
            )
            .overlay(alignment: .top) {
                if tone != .clear {
                    Rectangle()
                        .fill(Surface.topHighlight)
                        .frame(height: 1)
                        .padding(.horizontal, radius * 0.7)
                }
            }
            .shadow(color: Color.black.opacity(tone == .clear ? 0 : 0.35), radius: 22, x: 0, y: 10)
    }

    private var backgroundFill: LinearGradient {
        switch tone {
        case .raised: return Surface.raised
        case .sunken: return Surface.sunken
        case .clear: return LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Hairline

struct Hairline: View {
    var vertical: Bool = false
    var inset: CGFloat = 0
    var strong: Bool = false

    var body: some View {
        Rectangle()
            .fill(strong ? Palette.hairlineStrong : Palette.hairline)
            .frame(width: vertical ? Metrics.hairline : nil,
                   height: vertical ? nil : Metrics.hairline)
            .padding(vertical ? .vertical : .horizontal, inset)
    }
}

// MARK: - Caps label

struct CapsLabel: View {
    let text: String
    var accent: Bool = false
    var body: some View {
        Text(text)
            .font(Typeface.micro)
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundStyle(accent ? Palette.ember : Palette.inkTertiary)
    }
}

// MARK: - Progress ring

/// A full-circle gauge. Starts at 12 o'clock and sweeps clockwise, like a
/// clock — the one shape that justifies a ring in this app.
struct RingGauge: View {
    var progress: Double
    var lineWidth: CGFloat = 2
    var tint: Color = Palette.ember
    var track: Color = Palette.hairline

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Status dot

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 3)
                    .scaleEffect(on ? 2.1 : 1)
                    .opacity(on ? 0 : 0.9)
            )
            .onAppear {
                guard pulsing, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
                    on = true
                }
            }
    }
}

// MARK: - Press feedback

/// Scales on touch-down (not on release) and springs back. Every tappable
/// thing in the app uses this so the whole surface feels like one material.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

// MARK: - Empty state

struct EmptyNote: View {
    let text: String
    var body: some View {
        HStack(spacing: Space.s) {
            Rectangle()
                .fill(Palette.inkQuaternary)
                .frame(width: 14, height: 1)
            Text(text)
                .font(Typeface.body)
                .foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Key value row

/// The workhorse row: label left in tertiary, value right in primary, aligned
/// on a baseline. Used by the panel headers and the status strip.
struct KeyValueRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Typeface.caption)
                .tracking(0.6)
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: Space.m)
            value()
        }
    }
}
