import SwiftUI

// MARK: - Ambient Background

/// Layered background: warm linen gradient + organic ambient shapes + subtle grain texture.
/// Zero bundled assets — everything is procedurally drawn.
struct FLAmbientBackground: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [AppTheme.bg, AppTheme.bgDeep.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      ambientShapes

      FLGrainTexture()
        .opacity(0.032)
    }
  }

  private var ambientShapes: some View {
    GeometryReader { geo in
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                AppTheme.accent.opacity(0.06),
                AppTheme.accent.opacity(0.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: geo.size.width * 0.5
            )
          )
          .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9)
          .offset(x: geo.size.width * 0.35, y: -geo.size.height * 0.08)

        Circle()
          .fill(
            RadialGradient(
              colors: [
                AppTheme.sage.opacity(0.05),
                AppTheme.sage.opacity(0.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: geo.size.width * 0.4
            )
          )
          .frame(width: geo.size.width * 0.7, height: geo.size.width * 0.7)
          .offset(x: -geo.size.width * 0.3, y: geo.size.height * 0.55)

        Circle()
          .fill(
            RadialGradient(
              colors: [
                AppTheme.oat.opacity(0.04),
                AppTheme.oat.opacity(0.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: geo.size.width * 0.25
            )
          )
          .frame(width: geo.size.width * 0.5, height: geo.size.width * 0.5)
          .offset(x: geo.size.width * 0.05, y: geo.size.height * 0.25)
      }
    }
  }
}

// MARK: - Grain Texture

/// Procedural noise drawn via Canvas. Felt, not seen — adds analog warmth.
struct FLGrainTexture: View {
  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 3
      var x: CGFloat = 0
      while x < size.width {
        var y: CGFloat = 0
        while y < size.height {
          let hash = pseudoRandom(x: Int(x), y: Int(y))
          if hash > 0.55 {
            let brightness = hash * 0.5
            let rect = CGRect(x: x, y: y, width: 1, height: 1)
            context.fill(
              Path(rect),
              with: .color(
                Color(
                  red: Double(brightness),
                  green: Double(brightness * 0.95),
                  blue: Double(brightness * 0.88)
                )
              )
            )
          }
          y += step
        }
        x += step
      }
    }
    .allowsHitTesting(false)
  }

  private func pseudoRandom(x: Int, y: Int) -> CGFloat {
    var seed = UInt64(x &* 374_761_393 &+ y &* 668_265_263)
    seed = (seed ^ (seed >> 13)) &* 1_274_126_177
    seed = seed ^ (seed >> 16)
    return CGFloat(seed % 1000) / 1000.0
  }
}
