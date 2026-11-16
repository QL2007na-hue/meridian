//
//  Skin.swift
//  Meridian — the appearance layer.
//
//  A skin is the whole look of the clock: canvas, numerals, accent, type face,
//  weight, gradient and ring. Six presets ship; anything the presets expose can
//  be changed and the change is stored in state.json. Because every preset is a
//  dark canvas, the panel column can keep one neutral ramp — the accent is the
//  only thing the panels borrow from the skin.
//

import SwiftUI

// MARK: - Colour

/// An sRGB triple in 0...1. Stored as numbers rather than a hex string so a
/// colour picker can round-trip without parsing.
struct RGB: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    /// Spelled out because the hue initialiser below suppresses the memberwise
    /// one — and a colour type whose only initialiser is HSV would be useless to
    /// the presets, which are written in RGB.
    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()))
    }

    static func hex(_ value: UInt32) -> RGB {
        RGB(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    /// Mix toward white. Used to derive a gradient's second stop from a single
    /// swatch, so a one-tap recolour still reads as "lit from above".
    func lightened(_ amount: Double) -> RGB {
        mixed(with: RGB(r: 1, g: 1, b: 1), amount: amount)
    }

    /// Mix toward black. The counterpart to `lightened`, used by the vignette
    /// background, whose corners have to be darker than any shipped canvas.
    func darkened(_ amount: Double) -> RGB {
        mixed(with: RGB(r: 0, g: 0, b: 0), amount: amount)
    }

    /// Linear blend toward another colour. Separate from `lightened` because the
    /// gradient background needs to walk the canvas toward a *derived* stop
    /// without assuming the destination is white.
    func mixed(with other: RGB, amount: Double) -> RGB {
        let t = max(0, min(1, amount))
        return RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t
        )
    }

    // MARK: HSV

    /// Hue is in turns (0...1), saturation and brightness in 0...1 — the same
    /// convention `Color(hue:saturation:brightness:)` uses, so a value can cross
    /// into either side without a unit conversion at the call site.
    struct HSV: Equatable {
        var hue: Double
        var saturation: Double
        var value: Double
    }

    /// RGB → HSV. Unlike SwiftUI's `Color` there is no way to read a channel back
    /// out, which is exactly why the skin stores numbers: a hue slider can round
    /// trip through this without ever asking the renderer a question.
    var hsv: HSV {
        let high = max(r, max(g, b))
        let low = min(r, min(g, b))
        let delta = high - low

        var hue = 0.0
        if delta > 0.000_001 {
            if high == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        return HSV(
            hue: hue,
            saturation: high == 0 ? 0 : delta / high,
            value: high
        )
    }

    /// HSV → RGB. `hue` is in turns so a slider that speaks degrees divides by
    /// 360 exactly once, here or at the slider — never in two places.
    init(hue: Double, saturation: Double, value: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        let s = min(1, max(0, saturation))
        let v = min(1, max(0, value))

        let chroma = v * s
        let x = chroma * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - chroma

        switch Int(h * 6) % 6 {
        case 0: self.init(r: chroma + m, g: x + m, b: m)
        case 1: self.init(r: x + m, g: chroma + m, b: m)
        case 2: self.init(r: m, g: chroma + m, b: x + m)
        case 3: self.init(r: m, g: x + m, b: chroma + m)
        case 4: self.init(r: x + m, g: m, b: chroma + m)
        default: self.init(r: chroma + m, g: m, b: x + m)
        }
    }

    /// Rotate the hue by `degrees`, keeping saturation and brightness. A neutral
    /// colour has no hue to rotate, so it comes back untouched — that is what
    /// keeps the "no colour" presets neutral when a background hue offset moves.
    func hueShifted(degrees: Double) -> RGB {
        let current = hsv
        guard current.saturation > 0 else { return self }
        return RGB(
            hue: current.hue + degrees / 360,
            saturation: current.saturation,
            value: current.value
        )
    }

    /// Replace the hue (in degrees — the unit every slider here speaks) and the
    /// saturation, keeping the current brightness. Call sites pass the existing
    /// saturation when they only mean "turn the wheel".
    func withHueSaturation(hue degrees: Double, saturation: Double) -> RGB {
        RGB(hue: degrees / 360, saturation: saturation, value: hsv.value)
    }
}

// MARK: - Faces

enum DigitFace: String, Codable, CaseIterable, Identifiable {
    case rounded
    case standard
    case serif
    case mono

    var id: String { rawValue }

    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .standard: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    var label: String {
        switch self {
        case .rounded: return "圆体"
        case .standard: return "无衬线"
        case .serif: return "衬线"
        case .mono: return "等宽"
        }
    }
}

enum DigitWeight: String, Codable, CaseIterable, Identifiable {
    case thin
    case light
    case regular
    case medium
    case bold

    var id: String { rawValue }

    var value: Font.Weight {
        switch self {
        case .thin: return .ultraLight
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    var label: String {
        switch self {
        case .thin: return "极细"
        case .light: return "细"
        case .regular: return "常规"
        case .medium: return "中"
        case .bold: return "粗"
        }
    }
}

enum RingFace: String, Codable, CaseIterable, Identifiable {
    case ticks
    case arc
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ticks: return "刻度"
        case .arc: return "弧"
        case .none: return "无"
        }
    }
}

// MARK: - Skin

struct ClockSkin: Codable, Equatable {
    /// Identifies the preset this skin started from; "custom" once edited.
    var presetID: String
    var name: String

    var canvas: RGB
    var glow: RGB
    var ink: RGB
    var gradientTo: RGB
    var accent: RGB

    var face: DigitFace
    var weight: DigitWeight
    var gradient: Bool
    var ring: RingFace

    /// True for the two near-black canvases, so the ambient wash can stay subtle.
    var isDeepBlack: Bool

    // MARK: Derived

    var inkColor: Color { ink.color }
    var accentColor: Color { accent.color }
    var canvasColor: Color { canvas.color }

    /// The numeral fill. A gradient runs from the ink colour at the top to
    /// `gradientTo` at the bottom, which is what makes the StandBy preset read
    /// as "lit from above" rather than as a flat fill.
    var numeralStyle: AnyShapeStyle {
        if gradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [ink.color, gradientTo.color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(ink.color)
    }

    func numerals(_ size: CGFloat) -> Font {
        .system(size: size, weight: weight.value, design: face.design).monospacedDigit()
    }

    // MARK: Tolerant decoding

    init(presetID: String, name: String, canvas: RGB, glow: RGB, ink: RGB,
         gradientTo: RGB, accent: RGB, face: DigitFace, weight: DigitWeight,
         gradient: Bool, ring: RingFace, isDeepBlack: Bool) {
        self.presetID = presetID
        self.name = name
        self.canvas = canvas
        self.glow = glow
        self.ink = ink
        self.gradientTo = gradientTo
        self.accent = accent
        self.face = face
        self.weight = weight
        self.gradient = gradient
        self.ring = ring
        self.isDeepBlack = isDeepBlack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? ClockSkin.graphite.presetID
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ClockSkin.graphite.name
        canvas = (try? c.decodeIfPresent(RGB.self, forKey: .canvas)) ?? ClockSkin.graphite.canvas
        glow = (try? c.decodeIfPresent(RGB.self, forKey: .glow)) ?? ClockSkin.graphite.glow
        ink = (try? c.decodeIfPresent(RGB.self, forKey: .ink)) ?? ClockSkin.graphite.ink
        gradientTo = (try? c.decodeIfPresent(RGB.self, forKey: .gradientTo)) ?? ClockSkin.graphite.gradientTo
        accent = (try? c.decodeIfPresent(RGB.self, forKey: .accent)) ?? ClockSkin.graphite.accent
        face = (try? c.decodeIfPresent(DigitFace.self, forKey: .face)) ?? ClockSkin.graphite.face
        weight = (try? c.decodeIfPresent(DigitWeight.self, forKey: .weight)) ?? ClockSkin.graphite.weight
        gradient = (try? c.decodeIfPresent(Bool.self, forKey: .gradient)) ?? false
        ring = (try? c.decodeIfPresent(RingFace.self, forKey: .ring)) ?? ClockSkin.graphite.ring
        isDeepBlack = (try? c.decodeIfPresent(Bool.self, forKey: .isDeepBlack)) ?? false
    }

    // MARK: Presets

    /// The default: graphite canvas, bone ink, one amber accent, light rounded
    /// numerals. Everything else in this list is a variation on it.
    static let graphite = ClockSkin(
        presetID: "graphite",
        name: "石墨",
        canvas: RGB.hex(0x08090B),
        glow: RGB.hex(0xE0A662),
        ink: RGB.hex(0xF4F1EC),
        gradientTo: RGB.hex(0xF4F1EC),
        accent: RGB.hex(0xE0A662),
        face: .rounded,
        weight: .light,
        gradient: false,
        ring: .ticks,
        isDeepBlack: false
    )

    /// The iOS StandBy reading: pure black, a blue-to-sky numeral gradient and a
    /// heavy rounded face. Big, loud, and the one preset that is genuinely
    /// different in kind rather than in hue.
    static let standBy = ClockSkin(
        presetID: "standby",
        name: "悬浮蓝",
        canvas: RGB.hex(0x000000),
        glow: RGB.hex(0x2F6BFF),
        ink: RGB.hex(0x3B76FF),
        gradientTo: RGB.hex(0x9BD8FF),
        accent: RGB.hex(0x5AA2FF),
        face: .rounded,
        weight: .bold,
        gradient: true,
        ring: .arc,
        isDeepBlack: true
    )

    static let ember = ClockSkin(
        presetID: "ember",
        name: "灯下琥珀",
        canvas: RGB.hex(0x0B0704),
        glow: RGB.hex(0xE8A76A),
        ink: RGB.hex(0xE8A76A),
        gradientTo: RGB.hex(0xF0714A),
        accent: RGB.hex(0xE8A76A),
        face: .rounded,
        weight: .light,
        gradient: true,
        ring: .ticks,
        isDeepBlack: false
    )

    static let aurora = ClockSkin(
        presetID: "aurora",
        name: "极光",
        canvas: RGB.hex(0x04100E),
        glow: RGB.hex(0x63D8B0),
        ink: RGB.hex(0x9BE8CE),
        gradientTo: RGB.hex(0x5BC8E8),
        accent: RGB.hex(0x7FDCC0),
        face: .rounded,
        weight: .medium,
        gradient: true,
        ring: .arc,
        isDeepBlack: false
    )

    static let sanguine = ClockSkin(
        presetID: "sanguine",
        name: "赭红",
        canvas: RGB.hex(0x0A0608),
        glow: RGB.hex(0xE8836F),
        ink: RGB.hex(0xE8836F),
        gradientTo: RGB.hex(0xF3B98F),
        accent: RGB.hex(0xE8836F),
        face: .serif,
        weight: .light,
        gradient: true,
        ring: .ticks,
        isDeepBlack: false
    )

    /// The one that is not a colour: pure white on pure black, ultra-light,
    /// no accent, no ring. For people who want a clock and nothing else.
    static let mono = ClockSkin(
        presetID: "mono",
        name: "纯白墨",
        canvas: RGB.hex(0x000000),
        glow: RGB.hex(0xFFFFFF),
        ink: RGB.hex(0xFFFFFF),
        gradientTo: RGB.hex(0xFFFFFF),
        accent: RGB.hex(0xFFFFFF),
        face: .standard,
        weight: .thin,
        gradient: false,
        ring: .none,
        isDeepBlack: true
    )
}

// MARK: - Library

enum SkinLibrary {
    static let presets: [ClockSkin] = [
        .graphite, .standBy, .ember, .aurora, .sanguine, .mono
    ]

    static func preset(id: String) -> ClockSkin? {
        presets.first { $0.presetID == id }
    }

    /// Swatches offered to the customiser. Deliberately includes the two
    /// neutrals (bone, white) so a preset can be recoloured without changing
    /// its type or ring.
    static let swatches: [RGB] = [
        RGB.hex(0xF4F1EC),
        RGB.hex(0xFFFFFF),
        RGB.hex(0x9BD8FF),
        RGB.hex(0x7FDCC0),
        RGB.hex(0xE0A662),
        RGB.hex(0xF3B98F),
        RGB.hex(0xE8836F),
        RGB.hex(0xA8C4FF)
    ]
}

// MARK: - Environment

private struct SkinKey: EnvironmentKey {
    static let defaultValue = ClockSkin.graphite
}

extension EnvironmentValues {
    var skin: ClockSkin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}
