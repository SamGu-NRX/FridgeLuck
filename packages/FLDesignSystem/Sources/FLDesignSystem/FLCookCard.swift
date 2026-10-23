// FLDesignSystem — FLCookCard.
//
// A dish someone actually cooked: photo 1:1 or none, name in body semibold,
// who and when in caption, the one-line note as a body quote, the viewer's
// OWN fit meter (this dish against this viewer's kitchen), one button.
// No gradient scrim over photos, no white text on images — the direction
// bans both. Card radius 14, one hairline border, nothing else.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLCookCard: View {
    public let name: String
    /// Who cooked it ("Sam") — shown with `when` in caption.
    public let who: String
    /// When it was cooked ("last Tuesday").
    public let when: String
    /// The cook's one-line note, rendered as a quote.
    public let note: String?
    /// 1:1 photo, or nil for no photo (the layout simply omits it).
    public let photo: Image?
    public let fitHave: Int
    public let fitTotal: Int
    public let fitSwaps: Int?
    public let buttonTitle: String
    public let buttonHaptic: HapticRole?
    public let action: () -> Void

    @Environment(\.flScheme) private var scheme

    public init(
        name: String,
        who: String,
        when: String,
        note: String? = nil,
        photo: Image? = nil,
        fitHave: Int,
        fitTotal: Int,
        fitSwaps: Int? = nil,
        buttonTitle: String,
        buttonHaptic: HapticRole? = nil,
        action: @escaping () -> Void
    ) {
        self.name = name
        self.who = who
        self.when = when
        self.note = note
        self.photo = photo
        self.fitHave = fitHave
        self.fitTotal = fitTotal
        self.fitSwaps = fitSwaps
        self.buttonTitle = buttonTitle
        self.buttonHaptic = buttonHaptic
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo {
                photo
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220) // 1:1 within the card's width
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .flType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .lineLimit(1)

                Text("\(who) · \(when)")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))

                if let note {
                    // The quote device: one ink rule at the leading edge,
                    // stretching the note's height — no quotation marks.
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Theme.swiftColor(.ink, in: scheme))
                            .frame(width: 2)
                        Text(note)
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Note: \(note)")
                }

                FLFitMeter(have: fitHave, total: fitTotal, swaps: fitSwaps)

                FLButton(.primary, buttonTitle, haptic: buttonHaptic, action: action)
            }
            .padding(16)
        }
        .background(Theme.swiftColor(.bg, in: scheme))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous))
    }
}
#endif
