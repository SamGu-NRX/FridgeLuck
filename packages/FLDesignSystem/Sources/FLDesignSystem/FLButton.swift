// FLDesignSystem — FLButton.
//
// Three kinds, exactly as the direction allows: primary (ink filled),
// secondary (outlined), text. Copy is supplied by callers and written as
// verbs ("Cook this", "Add 14 to kitchen"); the button never invents labels.
//
// Press feedback lives in FLButtonStyle so every button in the system — and
// any custom control that adopts the style — behaves the same: scale 0.97
// over 120 ms, back with snap. Under Reduce Motion the scale and spring are
// replaced by the direction's opacity-only fade (reducedMotionPressOpacity
// over reducedMotionFadeMs) — no transform, feedback still perceptible.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLButton: View {
    public enum Kind { case primary, secondary, text }

    public let title: String
    public let kind: Kind
    /// Haptic paired with the action. The token table's surfaces name the
    /// pairings: mediumCommit for add-to-kitchen and cook-complete,
    /// lightConfirm for quiet confirmations. nil = silent.
    public let haptic: HapticRole?
    public let action: () -> Void

    @Environment(\.flScheme) private var scheme

    public init(
        _ kind: Kind = .primary,
        _ title: String,
        haptic: HapticRole? = nil,
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.title = title
        self.haptic = haptic
        self.action = action
    }

    public var body: some View {
        Button {
            if let haptic { FLHaptics.fire(haptic) }
            action()
        } label: {
            label
        }
        .buttonStyle(FLButtonStyle())
    }

    @ViewBuilder
    private var label: some View {
        switch kind {
        case .primary:
            Text(title)
                .flType(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(minHeight: CGFloat(Density.deciding.actionClearance ?? 48))
                .background(Theme.swiftColor(.ink, in: scheme))
                .foregroundStyle(Theme.swiftColor(.bg, in: scheme))
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous))

        case .secondary:
            Text(title)
                .flType(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(minHeight: CGFloat(Density.deciding.actionClearance ?? 48))
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                        .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous))

        case .text:
            Text(title)
                .flType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                // Text buttons carry no chrome, so nothing else enforces a
                // size: frame up to the hit-target floor in both axes.
                .frame(
                    minWidth: CGFloat(Theme.minimumHitTarget),
                    minHeight: CGFloat(Theme.minimumHitTarget)
                )
                .contentShape(Rectangle())
        }
    }
}

/// The system's only button style. Press: scale to 0.97 in 120 ms; release:
/// back with snap (0.22 s, bounce 0). Under Reduce Motion the transform is
/// replaced by an opacity-only fade to `reducedMotionPressOpacity` over
/// `reducedMotionFadeMs` — the direction's alternative for transforms; the
/// scale/spring pair never runs while the setting is on.
public struct FLButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration)
            .accessibilityElement(children: .contain)
    }
}

/// Reads Reduce Motion and applies the matching press feedback: the
/// scale/spring pair, or the opacity-only fade the direction defines as its
/// alternative. A ButtonStyle cannot read the environment itself, so the
/// body is a small view that can.
private struct PressFeedback: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.flReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        if reduceMotion {
            configuration.label
                .opacity(pressed ? Theme.reducedMotionPressOpacity : 1)
                .animation(
                    .linear(duration: Double(Theme.reducedMotionFadeMs) / 1000.0),
                    value: pressed
                )
        } else {
            configuration.label
                .scaleEffect(pressed ? Theme.pressScale : 1)
                .animation(
                    pressed
                        ? .spring(duration: Double(Theme.pressDurationMs) / 1000.0, bounce: 0)
                        : .fl(.snap),
                    value: pressed
                )
        }
    }
}
#endif
