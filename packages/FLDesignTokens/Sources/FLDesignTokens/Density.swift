// FLDesignTokens — the two density systems.
// From design-direction.md, "Density": two spacing systems, chosen by what
// the screen is for. `deciding` is generous (one thing per screenful);
// `dense` lets the eye scan 12 rows without scrolling.

/// One resolved spacing system. `nil` means "the other system owns this
/// measure" — deciding screens have no 44 pt row grid, dense screens have no
/// 48 pt action clearance. Reading `rowHeight ?? 0` is a bug: a nil means the
/// concept does not apply on that screen, and the view layer must treat it
/// that way.
public struct Density: Sendable, Equatable {

    /// Horizontal page margin.
    public let sideMargin: Double
    /// Vertical gap between blocks.
    public let blockGap: Double
    /// Space above the primary action. Deciding only.
    public let actionClearance: Double?
    /// The row grid. Dense only.
    public let rowHeight: Double?
    /// Spacing within a row. Dense only.
    public let rowInner: Double?
    /// Gap between chips. Dense only.
    public let chipGap: Double?
    /// Gap between sections. Dense only.
    public let sectionGap: Double?

    public init(
        sideMargin: Double, blockGap: Double, actionClearance: Double?,
        rowHeight: Double?, rowInner: Double?, chipGap: Double?, sectionGap: Double?
    ) {
        self.sideMargin = sideMargin
        self.blockGap = blockGap
        self.actionClearance = actionClearance
        self.rowHeight = rowHeight
        self.rowInner = rowInner
        self.chipGap = chipGap
        self.sectionGap = sectionGap
    }

    /// Tonight hero, cook-mode step, cook-complete. Generous.
    public static let deciding = Density(
        sideMargin: 24,
        blockGap: 32,
        actionClearance: 48,
        rowHeight: nil,
        rowInner: nil,
        chipGap: nil,
        sectionGap: nil
    )

    /// Kitchen, scan review, ingredient lists, taste profile, table. Dense.
    public static let dense = Density(
        sideMargin: 20,
        blockGap: 24,
        actionClearance: nil,
        rowHeight: 44,
        rowInner: 12,
        chipGap: 8,
        sectionGap: 24
    )
}
