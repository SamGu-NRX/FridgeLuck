// FLDesignSystem — FLTasteSentence.
//
// The correctable sentence: a sentence in body, the evidence count in mono
// caption (a real count — hidden under ten per the direction), Right /
// Wrong as two small secondary buttons. On Wrong the row greys and reads
// "Won't use this" with Undo. The correction is always recoverable — taste
// data is correctable memory, not a score, and there are no percentages.
//
// `initiallyRejected` exists so render tests can capture the wrong-state;
// callers leave it false.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLTasteSentence: View {
    public let sentence: String
    public let evidenceCount: Int
    public let onRight: () -> Void
    public let onWrong: () -> Void
    public let onUndo: () -> Void

    @State private var rejected: Bool
    @Environment(\.flScheme) private var scheme

    public init(
        sentence: String,
        evidenceCount: Int,
        initiallyRejected: Bool = false,
        onRight: @escaping () -> Void = {},
        onWrong: @escaping () -> Void = {},
        onUndo: @escaping () -> Void = {}
    ) {
        self.sentence = sentence
        self.evidenceCount = evidenceCount
        self.onRight = onRight
        self.onWrong = onWrong
        self.onUndo = onUndo
        _rejected = State(initialValue: initiallyRejected)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sentence)
                .flType(.body)
                .foregroundStyle(rejected ? Theme.swiftColor(.ink2, in: scheme) : Theme.swiftColor(.ink, in: scheme))

            Text("\(evidenceCount) seen")
                .flTracking(.evidence)
                .flType(.evidence)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))

            if rejected {
                wrongState
            } else {
                judgementButtons
            }
        }
        .padding(.vertical, 4)
        .opacity(rejected ? 0.75 : 1)
        .animation(.fl(.fade), value: rejected)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var judgementButtons: some View {
        HStack(spacing: 16) {
            smallSecondary("Right") {
                onRight()
            }
            smallSecondary("Wrong") {
                rejected = true
                onWrong()
            }
        }
    }

    @ViewBuilder
    private var wrongState: some View {
        HStack(spacing: 16) {
            Text("Won't use this")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            smallSecondary("Undo") {
                rejected = false
                onUndo()
            }
        }
        .transition(.opacity)
    }

    private func smallSecondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            FLHaptics.fire(.lightConfirm)
            action()
        } label: {
            Text(title)
                .flType(.secondary)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                        .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous))
        }
        .buttonStyle(FLButtonStyle())
    }
}
#endif
