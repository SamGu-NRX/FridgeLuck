// FLDesignTokens — Direction P ("Sam's pastel palette, rebuilt") palettes.
//
// Source of truth: `docs/design-round/direction-p/DIRECTION.md` §5 — the
// documented (canonical) hexes, including the four ADJUSTED text roles the
// direction derived from Sam's palette (textSecondary, accentInk, sageInk,
// oatInk). The doc's "AppTheme comment-vs-float drift" table resolves to the
// documented tokens used here; hues are never changed, only lightness, and
// fill/decorative uses keep Sam's original values.
//
// P's roles beyond the base ten: warm surfaces, chip fills, plate blocks,
// and per-mode text tones for sage/oat. Roles the P tables never document
// (ink3, hairline rule, cook-mode chips) bridge to a documented neighbour
// with a comment — nothing invented.

/// One resolved Direction P palette (one mode).
public struct PPalette: Sendable, Equatable {

    /// Page background. Light: #F5F0E8.
    public let bg: ColorToken
    /// Card ground. Light: #FEFCF8.
    public let surface: ColorToken
    /// Muted surface. Light: #F0E8DE.
    public let surfaceMuted: ColorToken
    /// Deep surface (hero plate wells). Light: #E8E0D4.
    public let surfaceDeep: ColorToken
    /// Primary text. Light: #2A2118.
    public let ink: ColorToken
    /// Secondary text — the ADJUSTED #6B6054 (was #887A6A; failed 4.5:1).
    public let ink2: ColorToken
    /// Tertiary text. P documents two text steps; this bridges to ink2.
    public let ink3: ColorToken
    /// Hairline. Package-defined warm hairline (P's tables document none).
    public let rule: ColorToken
    /// Hollow/dashed state-square border. Light: #6B6054 (doc non-text row).
    public let rule2: ColorToken
    /// The accent. Light: #C2613A, dark/cook: #D98059.
    public let accent: ColorToken
    /// Accent as TEXT on plain surfaces and as the filled-control colour —
    /// the ADJUSTED #A35131 (raw accent is 3.65:1 as text, 4.15:1 under white).
    public let accentInk: ColorToken
    /// Accent soft fill (terracotta-tint chip). Light: #EFDFD3.
    public let accentSoft: ColorToken
    /// Sage, saturated: have-state square fill; doubles as sage TEXT in dark.
    public let sage: ColorToken
    /// Sage as TEXT — the ADJUSTED #5F6E53 (raw sage is 3.13:1 as text).
    public let sageInk: ColorToken
    /// Sage chip fill. Light: #D3D9C8, dark: #424E3C.
    public let sageChip: ColorToken
    /// Sage plate block. Light: #B8C7AD (dark tables document no plate rows;
    /// bridges to the dark chip tone).
    public let sagePlate: ColorToken
    /// Oat, saturated: use-soon plate block / heroMid. Light: #D4B78F.
    public let oat: ColorToken
    /// Oat chip fill (hero chip). Light: #F0E0C7, dark: #3D362B.
    public let oatChip: ColorToken
    /// Oat as TEXT — the ADJUSTED #7C5C30 (raw oat on hero chip is 1.48:1);
    /// dark oat text is the doc's #CFB58C.
    public let oatInk: ColorToken
    /// Dusty rose: plate block. Light: #C09E96 (dark bridges to rose chip).
    /// A tint, never a signal.
    public let dustyRose: ColorToken
    /// Rose chip fill. Light: #E6D9D1, dark: #3B322F.
    public let roseChip: ColorToken
    /// Lifted accent for large digits / timer tiles. Light: #E39E7A, dark/cook: #EBB08C.
    public let accentLight: ColorToken
    /// Dark slab behind accent rows (deepOlive #1E1C17). Constant across modes.
    public let deepOlive: ColorToken
    /// Primary button fill. Light: the derived #A35131; dark/cook: #D98059.
    public let buttonFill: ColorToken
    /// Label on the primary button fill.
    public let buttonLabel: ColorToken
    /// Errors only. P's tables document none; the craft bar shares F's
    /// #C8321E in light and the dark-tuned #FF6B57 after.
    public let error: ColorToken

    public init(
        bg: ColorToken, surface: ColorToken, surfaceMuted: ColorToken, surfaceDeep: ColorToken,
        ink: ColorToken, ink2: ColorToken, ink3: ColorToken, rule: ColorToken,
        rule2: ColorToken, accent: ColorToken, accentInk: ColorToken, accentSoft: ColorToken,
        sage: ColorToken, sageInk: ColorToken, sageChip: ColorToken, sagePlate: ColorToken,
        oat: ColorToken, oatChip: ColorToken, oatInk: ColorToken,
        dustyRose: ColorToken, roseChip: ColorToken, accentLight: ColorToken,
        deepOlive: ColorToken, buttonFill: ColorToken, buttonLabel: ColorToken,
        error: ColorToken
    ) {
        self.bg = bg
        self.surface = surface
        self.surfaceMuted = surfaceMuted
        self.surfaceDeep = surfaceDeep
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.rule = rule
        self.rule2 = rule2
        self.accent = accent
        self.accentInk = accentInk
        self.accentSoft = accentSoft
        self.sage = sage
        self.sageInk = sageInk
        self.sageChip = sageChip
        self.sagePlate = sagePlate
        self.oat = oat
        self.oatChip = oatChip
        self.oatInk = oatInk
        self.dustyRose = dustyRose
        self.roseChip = roseChip
        self.accentLight = accentLight
        self.deepOlive = deepOlive
        self.buttonFill = buttonFill
        self.buttonLabel = buttonLabel
        self.error = error
    }

    /// Bridge to the closed ten-role palette: accent takes the yolk seat,
    /// accentSoft the wash, accentInk the text-on-wash.
    public var basePalette: Palette {
        Palette(
            bg: bg, ink: ink, ink2: ink2, ink3: ink3,
            rule: rule, rule2: rule2, yolk: accent, yolkSoft: accentSoft,
            yolkInk: accentInk, error: error
        )
    }
}

/// Direction P's three mode palettes.
public enum DirectionP {

    /// Light — Sam's approved pastel palette with the four adjusted text
    /// roles. Documented hexes canonical.
    public static let light = PPalette(
        bg: ColorToken(hex: 0xF5F0E8),
        surface: ColorToken(hex: 0xFEFCF8),
        surfaceMuted: ColorToken(hex: 0xF0E8DE),
        surfaceDeep: ColorToken(hex: 0xE8E0D4),
        ink: ColorToken(hex: 0x2A2118),
        ink2: ColorToken(hex: 0x6B6054),
        ink3: ColorToken(hex: 0x6B6054),
        rule: ColorToken(hex: 0xE4DBCA),
        rule2: ColorToken(hex: 0x6B6054),
        accent: ColorToken(hex: 0xC2613A),
        accentInk: ColorToken(hex: 0xA35131),
        accentSoft: ColorToken(hex: 0xEFDFD3),
        sage: ColorToken(hex: 0x7A8E6B),
        sageInk: ColorToken(hex: 0x5F6E53),
        sageChip: ColorToken(hex: 0xD3D9C8),
        sagePlate: ColorToken(hex: 0xB8C7AD),
        oat: ColorToken(hex: 0xD4B78F),
        oatChip: ColorToken(hex: 0xF0E0C7),
        oatInk: ColorToken(hex: 0x7C5C30),
        dustyRose: ColorToken(hex: 0xC09E96),
        roseChip: ColorToken(hex: 0xE6D9D1),
        accentLight: ColorToken(hex: 0xE39E7A),
        deepOlive: ColorToken(hex: 0x1E1C17),
        buttonFill: ColorToken(hex: 0xA35131),
        buttonLabel: ColorToken(hex: 0xFFFFFF),
        error: ColorToken(hex: 0xC8321E)
    )

    /// Dark — the doc's dark tokens (Twilight family).
    public static let dark = PPalette(
        bg: ColorToken(hex: 0x141210),
        surface: ColorToken(hex: 0x24211C),
        surfaceMuted: ColorToken(hex: 0x2E2924),
        surfaceDeep: ColorToken(hex: 0x1A1712),
        ink: ColorToken(hex: 0xF2EDE3),
        ink2: ColorToken(hex: 0xBDB09E),
        ink3: ColorToken(hex: 0xBDB09E),
        rule: ColorToken(hex: 0x2B2721),
        rule2: ColorToken(hex: 0xBDB09E),
        accent: ColorToken(hex: 0xD98059),
        accentInk: ColorToken(hex: 0xD98059),
        accentSoft: ColorToken(hex: 0x34241C),
        sage: ColorToken(hex: 0x94B085),
        sageInk: ColorToken(hex: 0x94B085),
        sageChip: ColorToken(hex: 0x424E3C),
        sagePlate: ColorToken(hex: 0x424E3C),
        oat: ColorToken(hex: 0x3D362B),
        oatChip: ColorToken(hex: 0x3D362B),
        oatInk: ColorToken(hex: 0xCFB58C),
        dustyRose: ColorToken(hex: 0x3B322F),
        roseChip: ColorToken(hex: 0x3B322F),
        accentLight: ColorToken(hex: 0xEBB08C),
        deepOlive: ColorToken(hex: 0x1E1C17),
        buttonFill: ColorToken(hex: 0xD98059),
        buttonLabel: ColorToken(hex: 0x1E1C17),
        error: ColorToken(hex: 0xFF6B57)
    )

    /// Cook — warm-dark: #1F1C17 ground, #2B2924 tile, #EBB08C timer digits.
    /// Roles the cook tables do not document bridge to the dark values.
    public static let cook = PPalette(
        bg: ColorToken(hex: 0x1F1C17),
        surface: ColorToken(hex: 0x2B2924),
        surfaceMuted: ColorToken(hex: 0x2E2924),
        surfaceDeep: ColorToken(hex: 0x2E2924),
        ink: ColorToken(hex: 0xF2EDE3),
        ink2: ColorToken(hex: 0xBDB09E),
        ink3: ColorToken(hex: 0xBDB09E),
        rule: ColorToken(hex: 0x332F28),
        rule2: ColorToken(hex: 0xBDB09E),
        accent: ColorToken(hex: 0xD98059),
        accentInk: ColorToken(hex: 0xD98059),
        accentSoft: ColorToken(hex: 0x34241C),
        sage: ColorToken(hex: 0x94B085),
        sageInk: ColorToken(hex: 0x94B085),
        sageChip: ColorToken(hex: 0x424E3C),
        sagePlate: ColorToken(hex: 0x424E3C),
        oat: ColorToken(hex: 0x3D362B),
        oatChip: ColorToken(hex: 0x3D362B),
        oatInk: ColorToken(hex: 0xCFB58C),
        dustyRose: ColorToken(hex: 0x3B322F),
        roseChip: ColorToken(hex: 0x3B322F),
        accentLight: ColorToken(hex: 0xEBB08C),
        deepOlive: ColorToken(hex: 0x1F1C17),
        buttonFill: ColorToken(hex: 0xD98059),
        buttonLabel: ColorToken(hex: 0x1F1C17),
        error: ColorToken(hex: 0xFF6B57)
    )

    /// Resolves one mode's palette.
    public static func palette(_ mode: DirectionMode) -> PPalette {
        switch mode {
        case .light: return light
        case .dark: return dark
        case .cook: return cook
        }
    }
}
