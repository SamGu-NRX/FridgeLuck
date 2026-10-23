// FLDesignTokens — semantic colour roles.
// Values are Direction F's colour table (design-direction.md, "Colour").
// Paper and hob are verbatim from that table; dark is the paper palette
// inverted, defined and documented below because the doc only names the rule.

/// Every colour role the system has. Ten roles, closed set: a colour that
/// cannot be named as one of these cannot enter the UI.
///
/// Use rules from the direction doc that the type system cannot enforce but
/// the names should remind: `error` is errors only (never "missing" or
/// "expiring"); `yolk` marks attention and always sits next to a word.
public enum ColorRole: String, Sendable, CaseIterable {
    /// Page background.
    case bg
    /// Text, primary buttons, filled states.
    case ink
    /// Secondary text.
    case ink2
    /// Tertiary text, placeholders, inactive tab. Never body-size text.
    case ink3
    /// Hairlines, 0.5 pt on 3x screens.
    case rule
    /// Hollow states (missing ingredient, unconfirmed item).
    case rule2
    /// Attention: tonight's pick marker, running timers, use-soon, selection.
    case yolk
    /// Yolk as a background behind text.
    case yolkSoft
    /// Text on yolk-soft.
    case yolkInk
    /// Errors only.
    case error
}

/// A fully resolved colour palette. Typed properties so removing or renaming
/// a role is a compile error in every consumer, not a silent runtime hole.
public struct Palette: Sendable, Equatable {

    /// Page background.
    public let bg: ColorToken
    /// Text, primary buttons, filled states.
    public let ink: ColorToken
    /// Secondary text.
    public let ink2: ColorToken
    /// Tertiary, placeholders, inactive tab.
    public let ink3: ColorToken
    /// Hairlines.
    public let rule: ColorToken
    /// Hollow states.
    public let rule2: ColorToken
    /// The one chromatic accent.
    public let yolk: ColorToken
    /// Yolk as a background behind text.
    public let yolkSoft: ColorToken
    /// Text on yolk-soft.
    public let yolkInk: ColorToken
    /// Errors only.
    public let error: ColorToken

    public init(
        bg: ColorToken, ink: ColorToken, ink2: ColorToken, ink3: ColorToken,
        rule: ColorToken, rule2: ColorToken, yolk: ColorToken, yolkSoft: ColorToken,
        yolkInk: ColorToken, error: ColorToken
    ) {
        self.bg = bg
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.rule = rule
        self.rule2 = rule2
        self.yolk = yolk
        self.yolkSoft = yolkSoft
        self.yolkInk = yolkInk
        self.error = error
    }

    /// Resolves a role against this palette.
    public func token(_ role: ColorRole) -> ColorToken {
        switch role {
        case .bg: return bg
        case .ink: return ink
        case .ink2: return ink2
        case .ink3: return ink3
        case .rule: return rule
        case .rule2: return rule2
        case .yolk: return yolk
        case .yolkSoft: return yolkSoft
        case .yolkInk: return yolkInk
        case .error: return error
        }
    }
}

/// The token namespace. Everything in the design system reads its values
/// through `Theme`, so the round's chosen direction swaps in here and nowhere
/// else.
public enum Theme {

    /// The Direction F colour table. Paper and hob are verbatim from
    /// `design-direction.md`; dark is defined here (the doc names the rule —
    /// "the paper palette inverted" — and leaves the values to this package).
    ///
    /// Dark rationale, token by token:
    /// - `bg #101110` — the ground takes paper-ink lightness; the faint green
    ///   cast of paper (G highest) survives so it reads "fridge interior", not
    ///   "developer terminal".
    /// - `ink #F0F1ED` — paper's background value, carried over the ground.
    /// - `ink2 #A6A7A1` — paper's ink2 lifted from #5E5E59 so body-adjacent
    ///   secondary text stays above 4.5:1 on the dark ground (7.8:1).
    /// - `ink3 #73746E` — tertiary, ≥3:1 on dark; never body-size text.
    /// - `rule #262722`, `rule2 #3B3C36` — hairlines and hollow states
    ///   darkened to stay quiet at hairline weight.
    /// - `yolk #F5C400` — unchanged; the one colour keeps its meaning.
    /// - `yolkSoft #2A2300`, `yolkInk #F5C400` — the hob pairing: a dark yolk
    ///   wash with yolk as the text on it (9.5:1).
    /// - `error #FF6B57` — the hob error hue, tuned for dark grounds (6.7:1).
    public static func palette(_ scheme: ColorScheme) -> Palette {
        switch scheme {
        case .paper:
            return Palette(
                bg: ColorToken(hex: 0xF7F8F6),
                ink: ColorToken(hex: 0x131313),
                ink2: ColorToken(hex: 0x5E5E59),
                ink3: ColorToken(hex: 0x8A8A84),
                rule: ColorToken(hex: 0xE4E5E0),
                rule2: ColorToken(hex: 0xCFD0CA),
                yolk: ColorToken(hex: 0xF5C400),
                yolkSoft: ColorToken(hex: 0xFFF3B8),
                yolkInk: ColorToken(hex: 0x6A5300),
                error: ColorToken(hex: 0xC8321E)
            )
        case .hob:
            return Palette(
                bg: ColorToken(hex: 0x0C0C0C),
                ink: ColorToken(hex: 0xF1F1ED),
                ink2: ColorToken(hex: 0x8E8E88),
                ink3: ColorToken(hex: 0x5A5A55),
                rule: ColorToken(hex: 0x252525),
                rule2: ColorToken(hex: 0x3A3A36),
                yolk: ColorToken(hex: 0xF5C400),
                yolkSoft: ColorToken(hex: 0x2A2300),
                yolkInk: ColorToken(hex: 0xF5C400),
                error: ColorToken(hex: 0xFF6B57)
            )
        case .dark:
            return Palette(
                bg: ColorToken(hex: 0x101110),
                ink: ColorToken(hex: 0xF0F1ED),
                ink2: ColorToken(hex: 0xA6A7A1),
                ink3: ColorToken(hex: 0x73746E),
                rule: ColorToken(hex: 0x262722),
                rule2: ColorToken(hex: 0x3B3C36),
                yolk: ColorToken(hex: 0xF5C400),
                yolkSoft: ColorToken(hex: 0x2A2300),
                yolkInk: ColorToken(hex: 0xF5C400),
                error: ColorToken(hex: 0xFF6B57)
            )
        }
    }

    /// Convenience: resolve one role in one scheme.
    public static func color(_ role: ColorRole, in scheme: ColorScheme) -> ColorToken {
        palette(scheme).token(role)
    }
}
