import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Ambient Background

/// Layered background: warm linen gradient + organic ambient shapes + subtle grain texture.
/// Zero bundled assets — everything is procedurally drawn.
struct FLAmbientBackground: View {
  @Environment(\.colorScheme) private var colorScheme
  let renderMode: FLAmbientBackgroundRenderMode

  init(renderMode: FLAmbientBackgroundRenderMode = .live) {
    self.renderMode = renderMode
  }

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
            Color(red: 0.06, green: 0.04, blue: 0.02).opacity(0.12),
            Color.clear,
            Color(red: 0.06, green: 0.04, blue: 0.02).opacity(0.08),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .blendMode(.multiply)
      }

      FLGrainTexture(isDarkMode: isDarkMode, renderMode: renderMode)
        .opacity(isDarkMode ? 0.036 : 0.032)
    }
  }

  private var ambientShapes: some View {
    let accentGlow = isDarkMode ? 0.08 : 0.06
    let sageGlow = isDarkMode ? 0.06 : 0.05
    let oatGlow = isDarkMode ? 0.05 : 0.04

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

      }
    }
  }
}

// MARK: - Grain Texture

/// Procedural noise drawn via Canvas. Felt, not seen — adds analog warmth.
struct FLGrainTexture: View {
  let isDarkMode: Bool
  let renderMode: FLAmbientBackgroundRenderMode

  var body: some View {
    switch renderMode {
    case .live:
      FLLiveGrainTexture(isDarkMode: isDarkMode)
    case .interactive:
      FLCachedGrainTexture(isDarkMode: isDarkMode)
    }
  }
}

private struct FLLiveGrainTexture: View {
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
                red: Double(brightness * 1.00),
                green: Double(brightness * 0.88),
                blue: Double(brightness * 0.74),
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

  private func pseudoRandom(x: Int, y: Int) -> Double {
    var seed = UInt64(x &* 374_761_393 &+ y &* 668_265_263)
    seed = (seed ^ (seed >> 13)) &* 1_274_126_177
    seed = seed ^ (seed >> 16)
    return Double(seed % 1000) / 1000.0
  }
}

private struct FLCachedGrainTexture: View {
  let isDarkMode: Bool
  @State private var grainImage: CGImage?
  @State private var stableSize: CGSize = .zero
  @State private var requestedCacheKey = ""

  var body: some View {
    GeometryReader { geo in
      Group {
        if let grainImage {
          Image(decorative: grainImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.none)
            .scaledToFill()
        } else {
          Color.clear
        }
      }
      .task(id: cacheKey(for: geo.size)) {
        await requestGrainImage(for: geo.size)
      }
    }
    .allowsHitTesting(false)
  }

  private func cacheKey(for size: CGSize) -> String {
    let stabilized = stabilizedSize(for: size)
    return FLCachedGrainTextureRenderer.cacheKey(for: stabilized, isDarkMode: isDarkMode)
  }

  @MainActor
  private func requestGrainImage(for size: CGSize) async {
    let stabilized = stabilizedSize(for: size)
    stableSize = stabilized

    let cacheKey = FLCachedGrainTextureRenderer.cacheKey(for: stabilized, isDarkMode: isDarkMode)
    guard requestedCacheKey != cacheKey else { return }
    requestedCacheKey = cacheKey

    let result = await FLCachedGrainTextureRenderer.image(for: stabilized, isDarkMode: isDarkMode)
    guard requestedCacheKey == result.cacheKey else { return }
    grainImage = result.image
  }

  private func stabilizedSize(for size: CGSize) -> CGSize {
    CGSize(
      width: max(stableSize.width, size.width),
      height: max(stableSize.height, size.height)
    )
  }
}

private actor FLCachedGrainImageCache {
  static let shared = FLCachedGrainImageCache()

  private let cache = NSCache<NSString, FLCachedGrainImageBox>()

  func image(forKey key: String) -> CGImage? {
    cache.object(forKey: key as NSString)?.image
  }

  func setImage(_ image: CGImage, forKey key: String) {
    cache.setObject(FLCachedGrainImageBox(image: image), forKey: key as NSString)
  }
}

private enum FLCachedGrainTextureRenderer {
  private static let renderQueue = DispatchQueue(
    label: "samgu.FridgeLuck.cachedGrainTexture",
    qos: .utility
  )
  private static let scaleFactor: CGFloat = 0.45
  private static let step: Int = 2

  static func image(for size: CGSize, isDarkMode: Bool) async -> (cacheKey: String, image: CGImage?)
  {
    let cacheKey = cacheKey(for: size, isDarkMode: isDarkMode)
    if let cached = await FLCachedGrainImageCache.shared.image(forKey: cacheKey) {
      return (cacheKey, cached)
    }

    let renderSize = renderedDimensions(for: size)
    let image = await withCheckedContinuation { continuation in
      renderQueue.async {
        continuation.resume(
          returning: makeImage(
            width: renderSize.width,
            height: renderSize.height,
            isDarkMode: isDarkMode
          )
        )
      }
    }

    if let image {
      await FLCachedGrainImageCache.shared.setImage(image, forKey: cacheKey)
    }

    return (cacheKey, image)
  }

  static func cacheKey(for size: CGSize, isDarkMode: Bool) -> String {
    let dimensions = renderedDimensions(for: size)
    return "\(dimensions.width)x\(dimensions.height)-\(isDarkMode ? "dark" : "light")"
  }

  private static func renderedDimensions(for size: CGSize) -> (width: Int, height: Int) {
    (
      width: max(Int(size.width * scaleFactor), 1),
      height: max(Int(size.height * scaleFactor), 1)
    )
  }

  private static func makeImage(width: Int, height: Int, isDarkMode: Bool) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))

    for x in stride(from: 0, to: width, by: step) {
      for y in stride(from: 0, to: height, by: step) {
        let hash = pseudoRandom(x: x, y: y)
        guard hash > 0.55 else { continue }

        let brightness = hash * (isDarkMode ? 0.34 : 0.5)
        let rgba = rgbaComponents(for: brightness, isDarkMode: isDarkMode)
        context.setFillColor(
          red: rgba.red,
          green: rgba.green,
          blue: rgba.blue,
          alpha: rgba.alpha
        )
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }

    return context.makeImage()
  }

  private static func rgbaComponents(for brightness: Double, isDarkMode: Bool)
    -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
  {
    if isDarkMode {
      return (
        red: CGFloat(brightness * 1.00),
        green: CGFloat(brightness * 0.88),
        blue: CGFloat(brightness * 0.74),
        alpha: 0.58
      )
    }

    return (
      red: CGFloat(brightness),
      green: CGFloat(brightness * 0.95),
      blue: CGFloat(brightness * 0.88),
      alpha: 1
    )
  }

  private static func pseudoRandom(x: Int, y: Int) -> Double {
    var seed = UInt64(x &* 374_761_393 &+ y &* 668_265_263)
    seed = (seed ^ (seed >> 13)) &* 1_274_126_177
    seed = seed ^ (seed >> 16)
    return Double(seed % 1000) / 1000.0
  }
}

private final class FLCachedGrainImageBox: NSObject {
  let image: CGImage

  init(image: CGImage) {
    self.image = image
  }
}
