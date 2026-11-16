//
//  Theme.swift
//  Meridian — the design system.
//
//  One accent (ember), one neutral ramp, one spacing scale, one radius scale.
//  Nothing in the app may hardcode a colour, size or radius: it comes from
//  here. That is what keeps a clock face calm at 3am and still precise at 3pm.
//

import SwiftUI

// MARK: - Colour

extension Color {
    /// 0xRRGGBB → sRGB colour. Used only by the palette below.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Graphite & Ember. A near-black warm canvas, a bone-white ink ramp, and a
/// single amber accent used sparingly for "now" and for the thing that matters
/// most on screen.
enum Palette {
    /// The canvas. Not pure black: a hair of warmth keeps it from looking dead
    /// on OLED and stops the ember accent from vibrating.
    static let canvas = Color(hex: 0x08090B)
    static let canvasLift = Color(hex: 0x0D0E11)
    static let canvasDeck = Color(hex: 0x14151A)

    /// Ink ramp. Warm neutral greys, not blue-greys — the accent is warm.
    static let ink = Color(hex: 0xF4F1EC)
    static let inkSecondary = Color(hex: 0xA9A39B)
    static let inkTertiary = Color(hex: 0x6F6A63)
    static let inkQuaternary = Color(hex: 0x46433F)

    /// The only accent. Amber at a low chroma: reads as lamp light, not as a
    /// warning.
    static let ember = Color(hex: 0xE0A662)
    static let emberSoft = Color(hex: 0xE0A662, alpha: 0.16)
    static let emberFaint = Color(hex: 0xE0A662, alpha: 0.07)

    /// Separators. Always 1px, always translucent — never a solid grey line.
    static let hairline = Color(hex: 0xFFFFFF, alpha: 0.075)
    static let hairlineStrong = Color(hex: 0xFFFFFF, alpha: 0.15)

    /// A cool counterweight used once, behind the panel column, so the right
    /// edge does not read as a flat black rectangle.
    static let coolDeep = Color(hex: 0x2B3440)

    /// The single way to lighten a surface. Every translucent white in the app
    /// goes through here so the ramp stays one ramp.
    static func wash(_ opacity: Double) -> Color {
        Color(hex: 0xFFFFFF, alpha: opacity)
    }
}

// MARK: - Surfaces

/// A card surface is a very short vertical gradient plus a hairline. Two
/// stacked surfaces are never both translucent: legibility collapses.
enum Surface {
    static let raised = LinearGradient(
        colors: [Color(hex: 0xFFFFFF, alpha: 0.062), Color(hex: 0xFFFFFF, alpha: 0.028)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let sunken = LinearGradient(
        colors: [Color(hex: 0xFFFFFF, alpha: 0.022), Color(hex: 0xFFFFFF, alpha: 0.048)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Inner light catch along the top edge of a card.
    static let topHighlight = LinearGradient(
        colors: [Color(hex: 0xFFFFFF, alpha: 0.10), Color(hex: 0xFFFFFF, alpha: 0)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Spacing

/// One 4-based scale. Every gap and inset in the app is one of these.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
    static let huge: CGFloat = 64
    static let vast: CGFloat = 96
}

// MARK: - Radii

enum Radius {
    static let chip: CGFloat = 8
    static let card: CGFloat = 18
    static let panel: CGFloat = 26
    static let stage: CGFloat = 34
}

// MARK: - Type scale

/// Six steps, no more. Display numerals use the rounded design with negative
/// tracking; labels use uppercase with positive tracking. Weight and grey do
/// the hierarchy work, not size alone.
enum Typeface {
    static func clock(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light, design: .rounded).monospacedDigit()
    }

    static func digit(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let display = Font.system(size: 44, weight: .light, design: .rounded)
    static let title = Font.system(size: 26, weight: .medium, design: .rounded)
    static let headline = Font.system(size: 19, weight: .semibold)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let caption = Font.system(size: 12, weight: .medium)
    static let micro = Font.system(size: 10, weight: .semibold)
}

// MARK: - Motion

/// Springs only. `settle` for anything that arrives, `snap` for anything you
/// touch, `drift` for slow ambient movement. Durations are never specified:
/// response is the parameter, so motion is always interruptible.
enum Motion {
    static let settle = Animation.spring(response: 0.44, dampingFraction: 0.86)
    static let snap = Animation.spring(response: 0.26, dampingFraction: 0.90)
    static let drift = Animation.spring(response: 0.70, dampingFraction: 0.94)
    static let fade = Animation.easeOut(duration: 0.30)
}

// MARK: - Layout metrics

enum Metrics {
    /// Outer inset of the whole stage.
    static let stageInset: CGFloat = 32
    static let panelStripWidth: CGFloat = 360
    /// Immersive glance: narrow on purpose. The numerals are centred in what is
    /// left, so every point this strip takes is a point the clock loses.
    static let glanceStripWidth: CGFloat = 240
    /// Focused agenda card.
    static let focusStripWidth: CGFloat = 380
    static let cardGap: CGFloat = 14
    static let rowHeight: CGFloat = 44
    static let hairline: CGFloat = 1
}

// MARK: - Small text helpers

/// Text-only helpers. They are declared on `Text` rather than on `View` because
/// `tracking`/`kerning` are `Text` API — a `View` extension cannot express the
/// letter-spacing these labels exist for.
extension Text {
    /// Uppercase micro label: the only place letter-spacing goes positive.
    ///
    /// Every step here must return `Text` — `.textCase` and `.foregroundStyle`
    /// are `View` modifiers that erase the type, which is why this chain stops
    /// at `font`/`tracking`/`foregroundColor`. Call sites that need uppercase
    /// pass an uppercase string; `CapsLabel` applies `.textCase` where the whole
    /// row is meant to be capitalised.
    func microLabel() -> Text {
        self
            .font(Typeface.micro)
            .tracking(1.6)
            .foregroundColor(Palette.inkTertiary)
    }

    /// Micro label that will sit on a dark surface at low contrast.
    func captionLabel(_ color: Color = Palette.inkSecondary) -> Text {
        self
            .font(Typeface.caption)
            .tracking(0.4)
            .foregroundColor(color)
    }
}
