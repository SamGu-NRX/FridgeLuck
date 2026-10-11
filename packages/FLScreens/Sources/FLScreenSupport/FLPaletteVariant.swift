// FLScreenSupport — palette variants for the render matrix.
//
// Sam's round decision on PR #95 made Direction H the provisional default,
// swappable BY THEME TOKENS: the morning pick replaces it without touching
// a screen. The render matrix therefore renders Tonight and Kitchen in BOTH
// the H and P palettes. Which palette tables those variants resolve to is
// the design-system package's job — it owns the token values.
//
// At this branch's base (overhaul/design-system at ba95187) FLDesignTokens
// carries one palette table per colour scheme; the H and P tables are
// underway on that branch. Until they land, BOTH variants resolve to the
// tables this checkout carries, and `FLRenderPaletteMapping.isProvisional`
// says so. When the base lands `Theme` tables for H and P, the one function
// below re-points and the tripwire test in FLScreenSupportTests fails on
// purpose until it is updated.
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

    /// True while both variants resolve to the same (currently carried)
    /// palette tables — i.e. before the base branch lands the H and P
    /// tables. The render manifest records this so no artifact can be
    /// mistaken for a true H/P comparison.
    public static var isProvisional: Bool { true }

    /// Resolve a variant's palette table for a colour scheme.
    public static func palette(
        for variant: FLPaletteVariant, in scheme: FLDesignTokens.ColorScheme
    ) -> FLDesignTokens.Palette {
        // Provisional: every variant resolves to the carried table.
        FLDesignTokens.Theme.palette(scheme)
    }
}
