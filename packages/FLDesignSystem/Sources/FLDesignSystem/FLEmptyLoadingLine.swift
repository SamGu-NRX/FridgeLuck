// FLDesignSystem — FLEmptyLoadingLine.
//
// Loading and empty states: a static layout plus one thin indeterminate
// line. NO shimmer, NO skeleton loops, NO gradient sweep — the direction
// names skeleton shimmer as a bug. The line is a 2 pt track with a small
// segment sweeping it linearly (transform only); under reduce motion the
// sweep stops and the line rests at partial opacity — still present, still
// honest, just not moving. The caller renders its static empty layout around
// it; copy is the caller's (written as directions, in the interface's voice).
#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

public struct FLEmptyLoadingLine: View {
    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// In determinate contexts a caller may want the line to pause; the
    /// sweep only runs when this is true.
    public var isLoading: Bool

    public init(isLoading: Bool = true) {
        self.isLoading = isLoading
    }

    public var body: some View {
        GeometryReader { proxy in
            let track = Theme.swiftColor(.rule2, in: scheme)
            let segment = Theme.swiftColor(.ink3, in: scheme)
            ZStack(alignment: .leading) {
                // Track.
                Capsule().fill(track).frame(height: 2)
                // Sweeping segment, linear, transform-only.
                if isLoading && !reduceMotion {
                    Capsule()
                        .fill(segment)
                        .frame(width: proxy.size.width * 0.28, height: 2)
                        .offset(x: sweepOffset(width: proxy.size.width))
                        .animation(
                            .linear(duration: 1.2).repeatForever(autoreverses: false),
                            value: animate
                        )
                } else {
                    // Reduce motion / stopped: one static line, dimmed.
                    Capsule()
                        .fill(segment)
                        .frame(width: proxy.size.width * (isLoading ? 0.4 : 1.0), height: 2)
                        .opacity(isLoading ? 0.6 : 1)
                        .animation(.fl(.fade), value: isLoading)
                }
            }
        }
        .frame(height: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? "Loading" : "Empty")
        .onAppear { animate = true }
    }

    @State private var animate = false

    private func sweepOffset(width: CGFloat) -> CGFloat {
        animate ? width : -width * 0.28
    }
}
#endif
