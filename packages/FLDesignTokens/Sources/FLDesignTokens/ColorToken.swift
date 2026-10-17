// FLDesignTokens — colour primitives.
// Foundation only: no SwiftUI, AppKit or UIKit imports; Linux-buildable.

/// A 24-bit sRGB colour held as doubles in 0...1. A plain value type on
/// purpose: the tokens package never names a platform colour type, so it
/// builds everywhere and the design system decides how to materialise it.
public struct ColorToken: Hashable, Sendable {

    /// Red channel, 0...1.
    public let red: Double
    /// Green channel, 0...1.
    public let green: Double
    /// Blue channel, 0...1.
    public let blue: Double

    /// Clamps channels into 0...1 so a typo can never produce an out-of-gamut token.
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `0xF7F8F6` style literal.
    public init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Parses `"#RRGGBB"` or `"RRGGBB"`. Returns nil for anything else.
    public init?(hex: String) {
        var body = hex
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// `#RRGGBB`, uppercase — the form the design-direction table uses.
    public var hexString: String {
        // Written as small explicit steps: a single String(format:) call over
        // three computed CVarArgs made the Swift 6 type-checker stall.
        func byte(_ channel: Double) -> String {
            let value = Int((channel * 255.0).rounded())
            let clamped = max(0, min(255, value))
            let text = String(clamped, radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        let r = byte(red)
        let g = byte(green)
        let b = byte(blue)
        return "#" + r + g + b
    }
}

/// One of the three resolved palettes a screen can run in.
///
/// - `paper`: the deciding palette (light). Tonight, recipe detail, lists.
/// - `hob`: cook mode. Its own thing; ignores the system setting entirely.
/// - `dark`: the system dark mode, defined here as **the paper palette
///   inverted** — figure and ground swap, the chromatic tokens keep their
///   meaning (yolk unchanged, the yolk wash and error hue move to the hob
///   values tuned for a dark ground). Values and rationale live in
///   `Palette.swift`; the design-direction doc only names the rule.
///
/// SwiftUI also declares a `ColorScheme`. The design-system package aliases
/// this type as `FLScheme` so call sites never hit the ambiguity.
public enum ColorScheme: String, Sendable, CaseIterable {
    case paper
    case hob
    case dark
}
