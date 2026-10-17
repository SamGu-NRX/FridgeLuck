// FLDesignSystem — FLChip.
//
// Quiet toggles for filters and tags. Selected: yolk-soft background with
// yolk-ink text — the only chromatic state a chip may take. Unselected:
// hairline outline, ink2 text. Radius is buttonOrChip (10); chips are never
// pills and never colour-coded beyond the one selected state. The paddings
// shape the look; the frame below shapes the touch area (44 pt floor).
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLChip: View {
    public let title: String
    public let isSelected: Bool
    public let action: () -> Void

    @Environment(\.flScheme) private var scheme

    public init(_ title: String, isSelected: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button {
            FLHaptics.fire(.lightConfirm)
            action()
        } label: {
            Text(title)
                .flType(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(
                    minWidth: CGFloat(Theme.minimumHitTarget),
                    minHeight: CGFloat(Theme.minimumHitTarget)
                )
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                        .fill(isSelected ? Theme.swiftColor(.yolkSoft, in: scheme) : Color.clear)
                )
                .foregroundStyle(
                    isSelected ? Theme.swiftColor(.yolkInk, in: scheme) : Theme.swiftColor(.ink2, in: scheme)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                        .stroke(
                            isSelected ? Color.clear : Theme.swiftColor(.rule2, in: scheme),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous))
        }
        .buttonStyle(FLButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
#endif
