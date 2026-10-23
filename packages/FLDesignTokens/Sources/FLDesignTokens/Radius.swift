// FLDesignTokens — radii.
// From design-direction.md, "Materials and depth": 10 (buttons, chips),
// 14 (photos, cook cards, timer tiles), 0 (rows), 36 (sheets, system).
// Nothing between 16 and 36 — the test suite enforces the gap.

/// The closed radius set. A raw value is the radius in points; the four cases
/// are everything that exists.
public enum Radius: Double, Sendable, CaseIterable {

    /// Rows. Square; separation is the hairline, not a curve.
    case row = 0

    /// Buttons and chips.
    case buttonOrChip = 10

    /// Photos, cook cards, timer tiles.
    case card = 14

    /// Sheets and system surfaces. The step is deliberate: nothing in
    /// content sits between a card and a sheet.
    case sheet = 36
}
