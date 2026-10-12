// FLDesignSystem — FLTasteSentence.
//
// The correctable sentence: a sentence in body, the evidence count in mono
// caption (a real count — hidden under ten per the direction), Right /
// Wrong as two small secondary buttons. On Wrong the row greys (ink → ink2,
// never an opacity dim — small text stays above the 4.5:1 floor) and reads
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
                // ink2, not ink3: the count is meaningful small text and the
                // component-role contrast test holds it to 4.5:1.
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))

            if rejected {
                wrongState
            } else {
                judgementButtons
            }
        }
        .padding(.vertical, 4)
        // No opacity dim on the rejected state: the ink → ink2 swap already
        // de-emphasises, and a dim would drag body-size text below 4.5:1.
        .animation(.fl(.fade), value: rejected)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var judgementButtons: some View {
        HStack(spacing: 16) {
            FLJudgementButton(title: "Right") {
                onRight()
            }
            FLJudgementButton(title: "Wrong") {
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
            FLJudgementButton(title: "Undo") {
                rejected = false
                onUndo()
            }
        }
        .transition(.opacity)
    }
}

/// The small outlined judgement button ("Right", "Wrong", "Undo") under the
/// taste sentence. Its paddings are visual only — the frame enforces the
/// 44 pt hit-target floor in both axes, because the bare look sits far
/// below it. Internal so the hit-region tests can measure it in isolation.
struct FLJudgementButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.flScheme) private var scheme

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
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
                .frame(
                    minWidth: CGFloat(Theme.minimumHitTarget),
                    minHeight: CGFloat(Theme.minimumHitTarget)
                )
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
