// FLDesignSystem — FLTimerTile.
//
// A cook-mode timer: radius 14 (card), hob surface, label in caption,
// digits in mono 56 yolk, and a thin ring that depletes LINEARLY — "a ring
// that eases is lying about time". Tap pauses, long-press removes.
//
// The tile always draws its own hob palette (dark ground, yolk digits) —
// it is a cook-mode object; it does not recolour per ambient scheme.
// The ring is value-driven (remaining/total), so it needs no easing choice:
// it advances only when the value advances. Reduce motion changes nothing
// here — the ring is information, and the direction says it keeps moving.
// Press feedback rides on FLButtonStyle (tap = pause), like every pressable.
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLTimerTile: View {
    public let label: String
    /// Seconds remaining.
    public let remaining: Int
    /// Seconds the timer started from.
    public let total: Int
    public let paused: Bool
    public let onPause: () -> Void
    public let onRemove: () -> Void

    public init(
        label: String,
        remaining: Int,
        total: Int,
        paused: Bool = false,
        onPause: @escaping () -> Void = {},
        onRemove: @escaping () -> Void = {}
    ) {
        self.label = label
        self.remaining = remaining
        self.total = total
        self.paused = paused
        self.onPause = onPause
        self.onRemove = onRemove
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(remaining) / Double(total)))
    }

    public var body: some View {
        Button {
            FLHaptics.fire(.lightConfirm)
            onPause()
        } label: {
            tileBody
        }
        .buttonStyle(FLButtonStyle())
        .onLongPressGesture {
            FLHaptics.fire(.mediumCommit)
            onRemove()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(accessibilityTime), \(paused ? "paused" : "running")")
        .accessibilityHint("Double-tap to pause. Long-press to remove.")
    }

    private var tileBody: some View {
        VStack(spacing: 8) {
            ZStack {
                ring
                digits
            }
            Text(label)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
        }
        .padding(16)
        .frame(width: 200, height: 200)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.bg, in: .hob))
        )
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous))
    }

    private var digits: some View {
        VStack(spacing: 2) {
            Text(timeText)
                .flTracking(.timer)
                .flType(.timer)
                .foregroundStyle(Theme.swiftColor(.yolk, in: .hob))
            if paused {
                // ink2, never ink3, and no dimming opacity over it: the
                // Paused label is meaningful small text on the hob ground,
                // held to the 4.5:1 floor by the component-role contrast
                // test. The state is cued by the label and the ring
                // stopping — not by dimming the digits.
                Text("Paused")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
            }
        }
        .animation(.fl(.fade), value: paused)
    }

    private var ring: some View {
        // Track: full ring in ink3. Progress: yolk arc, depleting linearly —
        // the animation is linear on the value, never eased on time.
        ZStack {
            Circle()
                .stroke(Theme.swiftColor(.ink3, in: .hob), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Theme.swiftColor(.yolk, in: .hob),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear, value: progress)
        }
        .padding(12)
    }

    private var timeText: String {
        // Built without String(format:) — that call stalls the Swift 6
        // type-checker on some argument shapes (see ColorToken.hexString).
        let minutes = remaining / 60
        let seconds = remaining % 60
        let secondText = seconds < 10 ? "0" + String(seconds) : String(seconds)
        return "\(minutes):\(secondText)"
    }

    private var accessibilityTime: String {
        let minutes = remaining / 60
        let seconds = remaining % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) min") }
        if seconds > 0 { parts.append("\(seconds) sec") }
        return parts.isEmpty ? "done" : parts.joined(separator: " ")
    }
}
#endif
