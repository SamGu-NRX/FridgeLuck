// FLDesignSystem — FLFitMeter.
//
// The one glyph that makes the app's promise visible: m small squares, n
// filled ink, the rest hollow with rule-2, plus a mono "9 of 10" count and
// an optional secondary "1 swap". Appears on Tonight, recipe detail, cook
// cards, and the Table. Never percentages — the direction bans them; counts
// only, and counts only when real.
//
// Numerals are monospaced system type, so "9 of 10" tracks Dynamic Type to
// the accessibility sizes. The whole meter is one accessibility element
// reading "9 of 10, 1 swap" so VoiceOver gets the sentence, not 10 squares.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLFitMeter: View {
    public let have: Int
    public let total: Int
    /// Optional number of single swaps that would complete the dish.
    public let swaps: Int?

    @Environment(\.flScheme) private var scheme

    public init(have: Int, total: Int, swaps: Int? = nil) {
        self.have = have
        self.total = total
        self.swaps = swaps
    }

    private var countText: String {
        "\(have) of \(total)"
    }

    private var swapsText: String? {
        guard let swaps, swaps > 0 else { return nil }
        return swaps == 1 ? "1 swap" : "\(swaps) swaps"
    }

    public var body: some View {
        HStack(spacing: 8) {
            squares
            Text(countText)
                .flTracking(.fitCount)
                .flType(.fitCount)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            if let swapsText {
                Text(swapsText)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([countText, swapsText].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var squares: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(total, 0), id: \.self) { index in
                // Squares stay squares (radius row = 0). Filled = have (ink),
                // hollow = missing, stroked with rule-2.
                if index < have {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Theme.swiftColor(.ink, in: scheme))
                        .frame(width: 10, height: 10)
                } else {
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .accessibilityHidden(true) // the count text carries the meaning
    }
}
#endif
