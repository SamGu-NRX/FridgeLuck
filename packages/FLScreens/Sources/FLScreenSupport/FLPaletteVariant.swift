// FLScreenSupport — palette variants for the render matrix.
//
// Sam's round decision on PR #95 made Direction H the provisional default,
// swappable BY THEME TOKENS: the morning pick replaces it without touching
// a screen. The render matrix therefore renders Tonight and Kitchen in BOTH
// the H and P palettes. Which palette tables those variants resolve to is
// the design-system package's job — it owns the token values.
//
// The base branch (overhaul/design-system at 3f84798) carries the real H
// and P palette tables (DirectionH.swift / DirectionP.swift), and the
// mapping below resolves each variant to its own table. `isProvisional`
// is false; the former tripwire test asserts the landed state instead.
//
// Foundation-only; no screen or view reads variants — only the render
// harness and the staged workflow do.

import FLDesignTokens

/// The visual directions the render matrix covers.
/// - `h`: Direction H, the provisional default (Sam's round decision).
/// - `p`: Direction P, Sam's approved pastel palette.
public enum FLPaletteVariant: String, Sendable, CaseIterable {
    case h
    case p
}

/// The variant → palette-table mapping, isolated here as the one place a
/// landed H/P palette changes.
public enum FLRenderPaletteMapping {

    /// False since the base branch landed the real H and P palette tables
    /// (DirectionH.swift / DirectionP.swift). Kept as a recorded flag so the
    /// render manifest can still mark artifacts, and so the mapping tests
    /// assert the landed state through it.
    public static var isProvisional: Bool { false }

    /// Resolve a variant's palette table for a colour scheme.
    ///
    /// F's `ColorScheme` axis maps onto the directions' mode axis:
    /// paper → light, hob → cook, dark → dark. The ten-role base palette
    /// comes from each direction's own tested bridge (`basePalette`); pills
    /// ride the direction tables' own fills — H defines them canonically,
    /// while P's canonical tables define none, so the mapping uses P's
    /// AA-tested chip and surface fills (flagged for a canonical P pill
    /// definition when P's round records one).
    public static func palette(
        for variant: FLPaletteVariant, in scheme: FLDesignTokens.ColorScheme
    ) -> FLDesignTokens.Palette {
        let mode: FLDesignTokens.DirectionMode = {
            switch scheme {
            case .paper: return .light
            case .hob: return .cook
            case .dark: return .dark
            }
        }()
        switch variant {
        case .h:
            let h = FLDesignTokens.DirectionH.palette(mode)
            let base = h.basePalette
            return FLDesignTokens.Palette(
                bg: base.bg, ink: base.ink, ink2: base.ink2, ink3: base.ink3,
                rule: base.rule, rule2: base.rule2,
                yolk: base.yolk, yolkSoft: base.yolkSoft, yolkInk: base.yolkInk,
                error: base.error, pillIdle: h.pillIdle, pillGone: h.pillGone
            )
        case .p:
            let p = FLDesignTokens.DirectionP.palette(mode)
            let base = p.basePalette
            return FLDesignTokens.Palette(
                bg: base.bg, ink: base.ink, ink2: base.ink2, ink3: base.ink3,
                rule: base.rule, rule2: base.rule2,
                yolk: base.yolk, yolkSoft: base.yolkSoft, yolkInk: base.yolkInk,
                error: base.error, pillIdle: p.oatChip, pillGone: p.surfaceMuted
            )
        }
    }
}
