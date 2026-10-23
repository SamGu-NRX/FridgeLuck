// FLDesignTokens — haptics.
// From design-direction.md, "Motion": haptics pair with motion — light on
// confirm row and chip, medium on "Add to kitchen" and cook-complete, rigid
// on timer done. Three roles, closed set.

/// When the phone should buzz. The design system maps these to the platform
/// feedback generator; feature code never names a generator.
public enum HapticRole: String, Sendable, CaseIterable {

    /// Confirm row, chip.
    case lightConfirm
    /// Add-to-kitchen, cook-complete.
    case mediumCommit
    /// Timer finished.
    case rigidTimerDone

    /// The surfaces each role belongs to, for docs and reviews. Not an API
    /// contract — the direction table in prose form.
    public var surfaces: [String] {
        switch self {
        case .lightConfirm: return ["confirm row", "chip"]
        case .mediumCommit: return ["add-to-kitchen", "cook-complete"]
        case .rigidTimerDone: return ["timer finished"]
        }
    }
}
