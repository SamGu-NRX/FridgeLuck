// FLDesignSystem — FLHairlineRow.
//
// The row device: content at least 44 pt tall, one 1 pt hairline (rule) at
// the bottom, press feedback on the whole row. Rows are buttons here — that
// is what makes the press scale apply and gives assistive tech a single
// actionable element. Content is caller-supplied; composition decides the
// layout (quantity rows, list rows, settings rows).
//
// Rows press-scale like everything else. Reduce motion keeps press scale.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLHairlineRow<Content: View>: View {
    private let content: Content
    private let haptic: HapticRole?
    private let action: (() -> Void)?

    @Environment(\.flScheme) private var scheme

    public init(
        haptic: HapticRole? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.haptic = haptic
        self.action = action
    }

    public var body: some View {
        let row = content
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) // dense.rowHeight
            .padding(.horizontal, 12)                                      // dense.rowInner
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.swiftColor(.rule, in: scheme))
                    .frame(height: 1)
            }

        if let action {
            Button {
                if let haptic { FLHaptics.fire(haptic) }
                action()
            } label: {
                row
            }
            .buttonStyle(FLButtonStyle())
        } else {
            row
        }
    }
}
#endif
