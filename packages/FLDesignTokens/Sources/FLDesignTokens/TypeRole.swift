// FLDesignTokens — type roles.
// Verbatim from design-direction.md, "Type": SF Pro for words, SF Mono for
// numbers, no serif, no rounded. Weights are the numeric CSS scale (400
// regular … 700 bold); the design system maps them to Font.Weight.

/// The typeface a role is set in. Two families, one job each.
public enum TypeFace: String, Sendable, CaseIterable {
    case sfProDisplay = "SF Pro Display"
    case sfProText = "SF Pro Text"
    case sfMono = "SF Mono"
}

/// The measured specification of one type role.
public struct TypeSpec: Sendable, Equatable {

    /// The typeface from the direction table.
    public let face: TypeFace
    /// Point size at the default Dynamic Type setting.
    public let size: Double
    /// Line height in points at the default setting.
    public let lineHeight: Double
    /// Weight on the numeric 100…900 scale.
    public let weight: Int
    /// Letter tracking in em (multiplied by the live size at render time).
    public let trackingEm: Double
    /// True for numeral roles: rendered with `.monospaced()` on the system
    /// font so it scales with Dynamic Type. SF Mono is inherently tabular.
    public let isMonospaced: Bool

    public init(
        face: TypeFace, size: Double, lineHeight: Double, weight: Int,
        trackingEm: Double, isMonospaced: Bool = false
    ) {
        self.face = face
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.trackingEm = trackingEm
        self.isMonospaced = isMonospaced
    }
}

/// A named text style. The direction table is this enum — a role that is not
/// a case here cannot be typeset.
public enum TypeRole: String, Sendable, CaseIterable {

    case dishTitle
    case screenTitle
    case cookStep
    case body
    case secondary
    case sectionLabel
    case caption
    case timer
    case fitCount
    case quantity
    case evidence

    public var spec: TypeSpec {
        switch self {
        case .dishTitle:
            // Wraps to 3 lines max, then truncates (enforced by the view layer).
            return TypeSpec(face: .sfProDisplay, size: 32, lineHeight: 34, weight: 700, trackingEm: -0.02)
        case .screenTitle:
            // Inline title, not the large-title collapse.
            return TypeSpec(face: .sfProDisplay, size: 28, lineHeight: 32, weight: 700, trackingEm: -0.015)
        case .cookStep:
            // On hob black; the largest body text in the app.
            return TypeSpec(face: .sfProDisplay, size: 26, lineHeight: 32, weight: 600, trackingEm: -0.01)
        case .body:
            return TypeSpec(face: .sfProText, size: 17, lineHeight: 24, weight: 400, trackingEm: 0)
        case .secondary:
            // ink-2.
            return TypeSpec(face: .sfProText, size: 15, lineHeight: 20, weight: 400, trackingEm: 0)
        case .sectionLabel:
            // Sentence case. Never uppercase, never tracked.
            return TypeSpec(face: .sfProText, size: 13, lineHeight: 16, weight: 600, trackingEm: 0)
        case .caption:
            // ink-2.
            return TypeSpec(face: .sfProText, size: 13, lineHeight: 16, weight: 400, trackingEm: 0)
        case .timer:
            // Tabular. Yolk on hob.
            return TypeSpec(face: .sfMono, size: 56, lineHeight: 56, weight: 500, trackingEm: -0.02, isMonospaced: true)
        case .fitCount:
            // Fit counts and totals; tabular.
            return TypeSpec(face: .sfMono, size: 17, lineHeight: 22, weight: 500, trackingEm: -0.01, isMonospaced: true)
        case .quantity:
            // Quantity, time, kcal; tabular, right-aligned in rows.
            return TypeSpec(face: .sfMono, size: 15, lineHeight: 20, weight: 400, trackingEm: -0.01, isMonospaced: true)
        case .evidence:
            // Evidence counts; ink-2.
            return TypeSpec(face: .sfMono, size: 13, lineHeight: 16, weight: 400, trackingEm: 0, isMonospaced: true)
        }
    }
}
