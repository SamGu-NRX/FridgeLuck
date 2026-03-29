import SwiftUI

struct FLShimmerModifier: ViewModifier {
  let active: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: CGFloat = -1

  func body(content: Content) -> some View {
    content
      .overlay {
        if active && !reduceMotion {
          GeometryReader { geo in
            LinearGradient(
              colors: [
                AppTheme.surfaceMuted.opacity(0),
                AppTheme.surface.opacity(0.6),
                AppTheme.surfaceMuted.opacity(0),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
            .frame(width: geo.size.width * 2)
            .offset(x: phase * geo.size.width * 2)
            .onAppear {
              phase = -1
              withAnimation(AppMotion.shimmer.repeatForever(autoreverses: false)) {
                phase = 1
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
          .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  func flShimmer(active: Bool = true) -> some View {
    modifier(FLShimmerModifier(active: active))
  }
}
