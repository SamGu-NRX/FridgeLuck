// FLDesignSystem — FLButton.
//
// Three kinds, exactly as the direction allows: primary (ink filled),
// secondary (outlined), text. Copy is supplied by callers and written as
// verbs ("Cook this", "Add 14 to kitchen"); the button never invents labels.
//
// Press feedback lives in FLButtonStyle so every button in the system — and
// any custom control that adopts the style — behaves the same: scale 0.97
// over 120 ms, back with snap. Reduce motion keeps the press scale (120 ms
// confirms the tap); it only turns the larger transitions into fades.
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
                .contentShape(Rectangle())
        }
    }
}

/// The system's only button style. Press: scale to 0.97 in 120 ms; release:
/// back with snap (0.22 s, bounce 0). Reduce motion does not remove press
/// feedback — the direction is explicit that the 120 ms scale confirms the tap.
public struct FLButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.pressScale : 1)
            .animation(
                configuration.isPressed
                    ? .spring(duration: Double(Theme.pressDurationMs) / 1000.0, bounce: 0)
                    : .fl(.snap),
                value: configuration.isPressed
            )
            .accessibilityElement(children: .contain)
    }
}
#endif
