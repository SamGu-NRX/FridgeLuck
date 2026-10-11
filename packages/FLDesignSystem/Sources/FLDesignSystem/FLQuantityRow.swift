// FLDesignSystem — FLQuantityRow.
//
// "200 g flour" at a glance: state square leading, name left in body,
// quantity right in mono, 44 pt tall, hairline bottom. Used in scan review,
// recipe detail, and Kitchen. The state square carries three honest states:
// filled = have, hollow = missing, dashed = unconfirmed (the scanner could
// not tell). Under reduce motion the press scale still confirms taps.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

/// State of one ingredient row.
public enum FLQuantityState: Sendable, Equatable {
    /// In the kitchen.
    case have
    /// Missing — needs a swap or a shop.
    case missing
    /// Unconfirmed — the scan could not tell.
    case unconfirmed
}

public struct FLQuantityRow: View {
    public let name: String
    public let quantity: String
    public let state: FLQuantityState
    public let haptic: HapticRole?
    public let action: (() -> Void)?

    @Environment(\.flScheme) private var scheme

    public init(
        name: String,
        quantity: String,
        state: FLQuantityState,
        haptic: HapticRole? = nil,
        action: (() -> Void)? = nil
    ) {
        self.name = name
        self.quantity = quantity
        self.state = state
        self.haptic = haptic
        self.action = action
    }

    public var body: some View {
        FLHairlineRow(haptic: haptic, action: action) {
            HStack(spacing: 12) {
                stateSquare
                Text(name)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(quantity)
                    .flTracking(.quantity)
                    .flType(.quantity)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(quantity), \(stateDescription)")
    }

    private var stateDescription: String {
        switch state {
        case .have: return "in your kitchen"
        case .missing: return "missing"
        case .unconfirmed: return "unconfirmed"
        }
    }

    @ViewBuilder
    private var stateSquare: some View {
        // Squares are radius row (0) — the closed radius set has nothing else.
        switch state {
        case .have:
            Rectangle()
                .fill(Theme.swiftColor(.ink, in: scheme))
                .frame(width: 10, height: 10)
        case .missing:
            Rectangle()
                .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .unconfirmed:
            Rectangle()
                .stroke(
                    Theme.swiftColor(.rule2, in: scheme),
                    style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])
                )
                .frame(width: 10, height: 10)
        }
    }
}
#endif
