//
//  SecondRing.swift
//  Meridian — the seconds, drawn as an instrument instead of a number.
//
//  Three faces: sixty ticks with one lit, a single swept arc, or nothing at all
//  (the Mono preset removes the instrument entirely). A trimmed circle can show
//  how far through the minute we are, but not *which* second it is — and that is
//  the only thing the default face exists to say. Each tick is a full-height
//  container with the mark pinned to the top, rotated around the ring's centre,
//  which keeps the geometry exact at any diameter without trigonometry.
//

import Foundation
import SwiftUI

/// Sixty ticks, one of them lit. Drawn from ticks rather than a trimmed circle
/// because the ring has to point at a specific second, not sweep a fraction.
struct SecondRing: View {
    /// Local second, 0...59.
    let second: Int
    var diameter: CGFloat = 52
    /// Off by default: the stage prints the seconds at the time's baseline, and
    /// the same two digits twice within 20pt reads as a bug, not as detail.
    var showsCenterLabel: Bool = false
    /// The skin's accent — never hardcoded here, or changing preset would leave
    /// one stray amber tick behind.
    var accent: Color = Palette.ember
    var face: RingFace = .ticks

    private var minorHeight: CGFloat { diameter * 0.09 }
    private var majorHeight: CGFloat { diameter * 0.17 }
    private var minorWidth: CGFloat { max(1, diameter * 0.018) }

    private var clampedSecond: Int { max(0, min(59, second)) }

    var body: some View {
        ZStack {
            switch face {
            case .ticks:
                ForEach(0..<60, id: \.self) { index in
                    tick(index)
                }
            case .arc:
                sweptArc
            case .none:
                EmptyView()
            }

            if showsCenterLabel {
                Text(String(format: "%02d", clampedSecond))
                    .font(Typeface.digit(diameter * 0.22, weight: .medium))
                    .foregroundStyle(accent.opacity(0.85))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: Faces

    private func tick(_ index: Int) -> some View {
        let isNow = index == clampedSecond
        let isMajor = index % 5 == 0
        let height = isNow ? majorHeight : (isMajor ? minorHeight * 1.7 : minorHeight)

        return VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(isNow ? accent : (isMajor ? Palette.hairlineStrong : Palette.hairline))
                .frame(width: isNow ? minorWidth * 1.6 : minorWidth, height: height)
            Spacer(minLength: 0)
        }
        .rotationEffect(.degrees(Double(index) * 6))
    }

    /// One continuous stroke, 0 → now, starting at twelve o'clock.
    private var sweptArc: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.hairline, lineWidth: max(1.5, diameter * 0.03))
            Circle()
                .trim(from: 0, to: max(0.004, Double(clampedSecond) / 59))
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: max(1.5, diameter * 0.03), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(max(0.8, diameter * 0.015))
    }
}
