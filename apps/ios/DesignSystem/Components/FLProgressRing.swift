import SwiftUI

struct FLProgressRing<CenterContent: View>: View {
  let progress: Double
  var size: CGFloat = AppTheme.Space.ringHeroSize
  var lineWidth: CGFloat = 12
  var trackColor: Color = AppTheme.surfaceMuted
  var fillColor: Color = AppTheme.accent
  var animateOnAppear: Bool = true
  @ViewBuilder var centerContent: () -> CenterContent

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var animatedProgress: Double = 0

  var body: some View {
    ZStack {
      Circle()
        .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

      Circle()
        .trim(from: 0, to: animatedProgress)
        .stroke(fillColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))

      centerContent()
    }
    .frame(width: size, height: size)
    .onAppear {
      if animateOnAppear && !reduceMotion {
        withAnimation(AppMotion.ringFillProgress) {
          animatedProgress = clampedProgress
        }
      } else {
        animatedProgress = clampedProgress
      }
    }
    .onChange(of: progress) { _, newValue in
      let target = min(max(newValue, 0), 1)
      if reduceMotion {
        animatedProgress = target
      } else {
        withAnimation(AppMotion.chartReveal) {
          animatedProgress = target
        }
      }
    }
    .accessibilityValue("\(Int(clampedProgress * 100)) percent")
  }

  private var clampedProgress: Double {
    min(max(progress, 0), 1)
  }
}

// Convenience initializer when no center content needed
extension FLProgressRing where CenterContent == EmptyView {
  init(
    progress: Double,
    size: CGFloat = AppTheme.Space.ringHeroSize,
    lineWidth: CGFloat = 12,
    trackColor: Color = AppTheme.surfaceMuted,
    fillColor: Color = AppTheme.accent,
    animateOnAppear: Bool = true
  ) {
    self.progress = progress
    self.size = size
    self.lineWidth = lineWidth
    self.trackColor = trackColor
    self.fillColor = fillColor
    self.animateOnAppear = animateOnAppear
    self.centerContent = { EmptyView() }
  }
}
