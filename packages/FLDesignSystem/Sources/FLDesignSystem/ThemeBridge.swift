// FLDesignSystem — Theme → SwiftUI bridge.
//
// FLDesignTokens is Foundation-only by design; this file is the only place
// that converts its tokens into SwiftUI types (Color, Font, Animation), plus
// the scheme environment and the haptic surface. Components never touch
// SwiftUI colour/font construction directly, so swapping the round's chosen
// direction later means touching this file and the token values only.
//
// Everything here is guarded so Linux builds an intentionally empty module.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The token colour scheme (paper / hob / dark). A distinct name so that
/// references inside this package are unambiguous next to SwiftUI.ColorScheme.
public typealias FLScheme = FLDesignTokens.ColorScheme

extension ColorToken {
    /// SwiftUI colour for this token, sRGB — the space the direction's hex
    /// values are defined in and the space the WCAG tests are computed in.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

extension Theme {
    /// SwiftUI colour for a semantic role in a scheme.
    /// (Distinct name from `Theme.color(_:in:)`, which returns ColorToken.)
    public static func swiftColor(_ role: ColorRole, in scheme: FLScheme) -> Color {
        color(role, in: scheme).color
    }
}

// MARK: Scheme environment

private struct FLSchemeKey: EnvironmentKey {
    static let defaultValue: FLScheme = .paper
}

extension EnvironmentValues {
    /// Which token palette the subtree draws with. Defaults to paper.
    public var flScheme: FLScheme {
        get { self[FLSchemeKey.self] }
        set { self[FLSchemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the token scheme for the subtree and keeps SwiftUI's own
    /// colourScheme in agreement: hob and dark are dark appearances, paper is
    /// light. System controls (scrollbars, text editors) then match the palette.
    public func flScheme(_ scheme: FLScheme) -> some View {
        environment(\.flScheme, scheme)
            .environment(\.colorScheme, scheme == .paper ? .light : .dark)
    }
}

// MARK: Motion

extension Animation {
    /// The direction's five named motions, straight from the tokens:
    /// snap/move/settle are springs with their token duration and bounce,
    /// fade is a 0.15 s ease-out, none is a zero-length animation.
    public static func fl(_ token: MotionToken) -> Animation {
        switch token {
        case .snap:
            return .spring(duration: MotionToken.snap.durationSeconds, bounce: MotionToken.snap.bounce ?? 0)
        case .move:
            return .spring(duration: MotionToken.move.durationSeconds, bounce: MotionToken.move.bounce ?? 0)
        case .settle:
            return .spring(duration: MotionToken.settle.durationSeconds, bounce: MotionToken.settle.bounce ?? 0)
        case .fade:
            return .easeOut(duration: MotionToken.fade.durationSeconds)
        case .none:
            return .linear(duration: MotionToken.none.durationSeconds)
        }
    }
}

// MARK: Type

extension TypeRole {
    /// The system text style each role scales with. Custom sizes do not track
    /// Dynamic Type on their own; anchoring the scaled metric to a system
    /// style makes every role (numerals included) grow with the user's
    /// setting up to the accessibility sizes.
    public var flScalingAnchor: Font.TextStyle {
        switch self {
        case .dishTitle: return .largeTitle
        case .screenTitle: return .title
        case .cookStep: return .title2
        case .body: return .body
        case .secondary: return .subheadline
        case .sectionLabel: return .caption
        case .caption: return .caption
        case .timer: return .largeTitle
        case .fitCount: return .body
        case .quantity: return .subheadline
        case .evidence: return .caption
        }
    }

    public var flFontWeight: Font.Weight {
        switch spec.weight {
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        default: return .regular
        }
    }
}

/// Applies a type role to any view: system font (SF Pro Text/Display via the
/// role's table), scaled by Dynamic Type around the role's anchor, monospaced
/// on the numeral roles, with the role's line height as line spacing.
///
/// Letter tracking is applied by `Text.flTracking` — SwiftUI only offers
/// kerning on Text, not on View — at the role's nominal size. At
/// accessibility sizes the em error stays sub-point for |t| ≤ 0.02.
public struct FLTypeModifier: ViewModifier {
    private let role: TypeRole
    @ScaledMetric private var size: CGFloat

    public init(role: TypeRole) {
        self.role = role
        _size = ScaledMetric(wrappedValue: CGFloat(role.spec.size), relativeTo: role.flScalingAnchor)
    }

    public func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: role.flFontWeight)
        content
            .font(role.spec.isMonospaced ? font.monospaced() : font)
            .lineSpacing(CGFloat(max(0, role.spec.lineHeight - role.spec.size)))
    }
}

extension View {
    public func flType(_ role: TypeRole) -> some View {
        modifier(FLTypeModifier(role: role))
    }
}

extension Text {
    /// Kerning for roles that carry tracking (display roles, numerals),
    /// chained BEFORE `flType`: kerning exists only on Text, while `flType`
    /// wraps into an opaque view via FLTypeModifier. SwiftUI only offers
    /// kerning on Text, not View,
    /// and kerning cannot read the scaled metric — so it applies at the
    /// role's nominal size. At accessibility sizes the em error stays
    /// sub-point for |t| ≤ 0.02, and body-size roles carry none at all.
    public func flTracking(_ role: TypeRole) -> Text {
        kerning(CGFloat(role.spec.size * role.spec.trackingEm))
    }
}

// MARK: Haptics

/// Fires a HapticRole on the platform generator. The role table lists the
/// surfaces each role belongs to; components accept an optional role on their
/// initializers rather than deciding internally.
public enum FLHaptics {
    public static func fire(_ role: HapticRole) {
        #if canImport(UIKit)
        switch role {
        case .lightConfirm:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumCommit:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigidTimerDone:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        #elseif canImport(AppKit)
        // macOS has no per-style impact generator; one coarse feedback hit.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}
#endif
