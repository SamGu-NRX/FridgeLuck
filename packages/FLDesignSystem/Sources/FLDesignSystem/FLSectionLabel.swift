// FLDesignSystem — FLSectionLabel.
//
// The 13/16 semibold label that heads groups of rows. Sentence case is a
// rule, not a style choice: this component never applies an uppercasing
// transform, and callers are expected to pass copy that is already sentence
// case ("In your kitchen", not "IN YOUR KITCHEN"). No numbered eyebrows —
// numbers belong to cook-mode steps only.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLSectionLabel: View {
    public let title: String

    @Environment(\.flScheme) private var scheme

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .flType(.sectionLabel)
            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            .accessibilityAddTraits(.isHeader)
    }
}
#endif
