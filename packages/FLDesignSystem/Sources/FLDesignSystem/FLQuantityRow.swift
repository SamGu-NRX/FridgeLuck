// FLDesignSystem — FLQuantityRow.
//
// "200 g flour" at a glance: state square leading, name left in body,
// quantity right in mono, 44 pt tall, hairline bottom. Used in scan review,
// recipe detail, and Kitchen. The state square carries the seven honest
// stock states of SPEC 3.2 — filled = have, half-filled = short, hollow =
// missing, dashed = unconfirmed, donut = quantity unknown, dim fill =
// assumed, dim dashed = stale evidence. Under reduce motion presses fade
// instead of scaling (FLButtonStyle).
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

/// State of one ingredient row. The fill level says presence; the line
/// style says certainty; ink vs ink2 says observed vs inferred or aged.
public enum FLQuantityState: Sendable, Equatable {
    /// In the kitchen, quantity confirmed.
    case have
    /// In the kitchen, but not enough for the recipe.
    case short
    /// Missing — needs a swap or a shop.
    case missing
    /// Unconfirmed — the scan could not tell.
    case unconfirmed
    /// In the kitchen, but the amount is unknown (an opened package).
    case quantityUnknown
    /// Assumed in stock from a record or a past cook — never observed now.
    case assumed
    /// Evidence is stale — confirmed once, not seen for a while.
    case stale
}

public struct FLQuantityRow: View {
    public let name: String
    public let quantity: String
    public let state: FLQuantityState
    public let haptic: HapticRole?
    public let action: (() -> Void)?

    @Environment(\.flScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    // One line while the row grid holds; at accessibility
                    // sizes the row grows and the name wraps instead of
                    // truncating away the dish.
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
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
        case .short: return "running short"
        case .missing: return "missing"
        case .unconfirmed: return "unconfirmed"
        case .quantityUnknown: return "in your kitchen, amount unknown"
        case .assumed: return "assumed in stock"
        case .stale: return "stock information stale"
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
        case .short:
            // Running short: filled to half — presence is partial.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.swiftColor(.rule2, in: scheme))
                    .frame(height: 5)
                Rectangle()
                    .fill(Theme.swiftColor(.ink, in: scheme))
                    .frame(height: 5)
            }
            .frame(width: 10, height: 10)
        case .quantityUnknown:
            // Amount unknown: filled, with a hole where the number would be.
            ZStack {
                Rectangle()
                    .fill(Theme.swiftColor(.ink, in: scheme))
                Circle()
                    .fill(Theme.swiftColor(.bg, in: scheme))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 10, height: 10)
        case .assumed:
            // Inferred presence, never observed: the dimmer fill.
            Rectangle()
                .fill(Theme.swiftColor(.ink2, in: scheme))
                .frame(width: 10, height: 10)
        case .stale:
            // Once confirmed, since aged: the dashed outline in ink2.
            Rectangle()
                .stroke(
                    Theme.swiftColor(.ink2, in: scheme),
                    style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])
                )
                .frame(width: 10, height: 10)
        }
    }
}
#endif
