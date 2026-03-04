import SwiftUI

// MARK: - Ambient Background

/// Layered background: warm linen gradient + organic ambient shapes + subtle grain texture.
/// Zero bundled assets — everything is procedurally drawn.
struct FLAmbientBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  private var isDarkMode: Bool {
    colorScheme == .dark
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: isDarkMode
          ? [AppTheme.bg, AppTheme.bgDeep]
          : [AppTheme.bg, AppTheme.bgDeep.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      ambientShapes

      if isDarkMode {
        LinearGradient(
          colors: [
            Color.black.opacity(0.30),
            Color.clear,
            Color.black.opacity(0.22),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .blendMode(.multiply)
      }

      FLGrainTexture(isDarkMode: isDarkMode)
        .opacity(isDarkMode ? 0.042 : 0.032)
    }
  }

  private var ambientShapes: some View {
    let accentGlow = isDarkMode ? 0.12 : 0.06
    let sageGlow = isDarkMode ? 0.10 : 0.05
    let oatGlow = isDarkMode ? 0.08 : 0.04

    return GeometryReader { geo in
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                AppTheme.accent.opacity(accentGlow),
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
                AppTheme.sage.opacity(sageGlow),
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
                AppTheme.oat.opacity(oatGlow),
                AppTheme.oat.opacity(0.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: geo.size.width * 0.25
            )
          )
          .frame(width: geo.size.width * 0.5, height: geo.size.width * 0.5)
          .offset(x: geo.size.width * 0.05, y: geo.size.height * 0.25)

        if isDarkMode {
          Circle()
            .fill(
              RadialGradient(
                colors: [
                  AppTheme.sageLight.opacity(0.11),
                  AppTheme.sageLight.opacity(0.0),
                ],
                center: .center,
                startRadius: 0,
                endRadius: geo.size.width * 0.45
              )
            )
            .frame(width: geo.size.width * 0.72, height: geo.size.width * 0.72)
            .offset(x: geo.size.width * 0.12, y: -geo.size.height * 0.20)
            .blendMode(.screen)
        }
      }
    }
  }
}

// MARK: - Grain Texture

/// Procedural noise drawn via Canvas. Felt, not seen — adds analog warmth.
struct FLGrainTexture: View {
  let isDarkMode: Bool

  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 3
      var x: CGFloat = 0
      while x < size.width {
        var y: CGFloat = 0
        while y < size.height {
          let hash = pseudoRandom(x: Int(x), y: Int(y))
          if hash > 0.55 {
            let brightness = hash * (isDarkMode ? 0.34 : 0.5)
            let rect = CGRect(x: x, y: y, width: 1, height: 1)
            let grainColor: Color
            if isDarkMode {
              grainColor = Color(
                red: Double(brightness * 0.95),
                green: Double(brightness * 0.90),
                blue: Double(brightness * 0.80),
                opacity: 0.58
              )
            } else {
              grainColor = Color(
                red: Double(brightness),
                green: Double(brightness * 0.95),
                blue: Double(brightness * 0.88)
              )
            }
            context.fill(
              Path(rect),
              with: .color(grainColor)
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
