// FLDesignTokens — theme-swappable layout tokens.
//
// Layout rules the shell and photo surfaces follow, expressed as tokens so a
// direction swap re-lays the shell without touching screen code. The values
// below are the task's shell/photo rules: hero photos frame at 3:2 and a
// photo never occupies more than 40% of its container's height. Every
// direction publishes its own `layout` (currently identical) — a direction
// that wants different photo geometry swaps this one struct.

/// Layout rules for photo surfaces and the shell.
public struct LayoutTokens: Sendable, Equatable {

    /// Photo frames are 3:2 (width per height): a 300 pt frame is 200 pt tall.
    public let photoAspectRatio: Double

    /// A photo never takes more than this fraction of its container's height.
    public let photoMaxHeightFraction: Double

    public init(photoAspectRatio: Double, photoMaxHeightFraction: Double) {
        self.photoAspectRatio = photoAspectRatio
        self.photoMaxHeightFraction = photoMaxHeightFraction
    }
}

extension Theme {
    /// Direction F's layout: 3:2 photos capped at 40% of container height.
    public static let layout = LayoutTokens(
        photoAspectRatio: 3.0 / 2.0,
        photoMaxHeightFraction: 0.4
    )
}

extension Theme {
    /// Minimum interactive hit target in points. Chips, text buttons and the
    /// small judgement buttons frame up to at least this in both axes,
    /// whatever their visual padding suggests — the Apple 44 pt floor, and
    /// the same measure as the dense row grid (`Density.dense.rowHeight`).
    public static let minimumHitTarget: Double = 44
}

extension DirectionH {
    /// Direction H's layout — same shell/photo rules today; the swap unit
    /// is the struct, so a direction-specific geometry changes only here.
    public static let layout = LayoutTokens(
        photoAspectRatio: 3.0 / 2.0,
        photoMaxHeightFraction: 0.4
    )
}

extension DirectionP {
    /// Direction P's layout — same shell/photo rules today; the swap unit
    /// is the struct, so a direction-specific geometry changes only here.
    public static let layout = LayoutTokens(
        photoAspectRatio: 3.0 / 2.0,
        photoMaxHeightFraction: 0.4
    )
}
