// FLDesignTokens — motion.
// Five tokens replace AppMotion.swift. Any animation that needs a sixth is
// probably decoration. Durations in seconds, spring bounce on the SwiftUI
// 0...1 scale; `fade` is an ease-out curve, so its bounce is nil; `none` is
// the absence of animation, so both measures are 0.

/// The five motion tokens. Frequency decides first: "next step" happens 8 to
/// 12 times per cook with wet hands (snap, no slower); tab switches happen
/// more than 20 times a session (none); cook-complete happens once a day and
/// may take 500 ms with one bounce (settle).
public enum MotionToken: String, Sendable, CaseIterable {

    /// Selection, chip toggle, row check, segment move, step change by voice.
    case snap
    /// Sheet detents, push to recipe, cook card expand, timer tile add.
    case move
    /// Drag release only: sheet flick, swipe-to-remove, timer-done ring.
    case settle
    /// Colour and opacity crossfades, content swap under a stable frame.
    case fade
    /// Tab switch, keyboard, anything a user does more than 20 times a session.
    case none

    /// Duration in seconds.
    public var durationSeconds: Double {
        switch self {
        case .snap: return 0.22
        case .move: return 0.34
        case .settle: return 0.50
        case .fade: return 0.15
        case .none: return 0
        }
    }

    /// Spring bounce; nil where the token is not a spring (`fade` is an
    /// ease-out, `none` is nothing).
    public var bounce: Double? {
        switch self {
        case .snap: return 0
        case .move: return 0.12
        case .settle: return 0.22
        case .fade: return nil
        case .none: return nil
        }
    }
}

/// Motion scalars that are not tokens: press feedback, reduced motion, and
/// the stagger budget. They live on the `Theme` namespace so the whole token
/// surface reads through one entry point.
extension Theme {

    /// Press feedback on every pressable (rows included): scale to 0.97.
    public static let pressScale: Double = 0.97

    /// …over 120 ms, and back with snap.
    public static let pressDurationMs: Int = 120

    /// Reduced-motion press feedback: while Reduce Motion is on, the press
    /// scale and spring are replaced by an opacity-only fade to this level —
    /// the direction's alternative for transforms. Transient by construction:
    /// the control returns to full opacity on release.
    public static let reducedMotionPressOpacity: Double = 0.6

    /// Reduced motion: transforms become opacity-only fades at this length;
    /// stagger goes to 0; the timer ring still moves because it is
    /// information; press feedback joins the fade — no scale or spring while
    /// the setting is on (`reducedMotionPressOpacity`).
    public static let reducedMotionFadeMs: Int = 150

    /// Stagger 40 ms, capped at 6 items, never blocking input. Beyond 6,
    /// items simply appear.
    public static let staggerMs: Int = 40

    /// Stagger cap.
    public static let staggerCap: Int = 6
}
