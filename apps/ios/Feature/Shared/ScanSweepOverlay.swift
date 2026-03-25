import SwiftUI

/// Animated scanning line overlay used by both ScanView and DemoModeOverlays.
struct ScanSweepOverlay: View {
  let isAnimating: Bool

  private static let cycleDuration: Double = 4.0

  var body: some View {
    TimelineView(.animation(paused: !isAnimating)) { context in
      let travel = Self.sweepPosition(at: context.date)

      GeometryReader { geo in
        let y = max(12, min(geo.size.height - 12, geo.size.height * travel))
        ZStack {
          LinearGradient(
            colors: [Color.clear, Color.white.opacity(0.04), Color.clear],
            startPoint: .top,
            endPoint: .bottom
          )

          Rectangle()
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.0),
                  Color.white.opacity(0.65),
                  Color.white.opacity(0.85),
                  Color.white.opacity(0.65),
                  Color.white.opacity(0.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(height: 1.5)
            .position(x: geo.size.width / 2, y: y)
            .shadow(color: Color.white.opacity(0.5), radius: 4, x: 0, y: 0)

          LinearGradient(
            colors: [
              AppTheme.accent.opacity(0.0),
              AppTheme.accent.opacity(0.18),
              AppTheme.accent.opacity(0.0),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 80)
          .position(x: geo.size.width / 2, y: y)
          .blur(radius: 8)
        }
      }
    }
  }

  /// Triangle wave from elapsed time — immune to external animation interference.
  private static func sweepPosition(at date: Date) -> CGFloat {
    let elapsed = date.timeIntervalSinceReferenceDate
    let phase = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    let triangle = phase <= 0.5 ? phase * 2 : 2.0 - phase * 2
    return 0.08 + CGFloat(triangle) * 0.84
  }
}
