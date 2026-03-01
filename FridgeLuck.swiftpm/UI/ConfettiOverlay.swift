import SwiftUI

/// A celebratory confetti burst overlay. Particles launch upward, spread horizontally,
/// and fall with gravity. Uses the app's warm palette -- no neon, no generic rainbow.
struct ConfettiOverlay: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var particles: [ConfettiParticle] = []
  @State private var isAnimating = false

  var particleCount: Int = 50
  var onComplete: (() -> Void)?

  var body: some View {
    GeometryReader { geo in
      ZStack {
        ForEach(particles) { particle in
          ConfettiPiece(particle: particle, isAnimating: isAnimating)
        }
      }
      .onAppear {
        guard !reduceMotion else {
          onComplete?()
          return
        }
        particles = Self.generateParticles(count: particleCount, in: geo.size)
        withAnimation(.easeOut(duration: AppMotion.confettiDuration)) {
          isAnimating = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AppMotion.confettiDuration + 0.3) {
          onComplete?()
        }
      }
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
  }

  private static func generateParticles(count: Int, in size: CGSize) -> [ConfettiParticle] {
    let colors: [Color] = [
      AppTheme.accent,
      AppTheme.accentLight,
      AppTheme.sage,
      AppTheme.sageLight,
      AppTheme.oat,
      AppTheme.dustyRose,
    ]

    return (0..<count).map { index in
      let startX = size.width * 0.5 + CGFloat.random(in: -40...40)
      let startY = size.height * 0.45

      return ConfettiParticle(
        id: index,
        startX: startX,
        startY: startY,
        endX: startX + CGFloat.random(in: -size.width * 0.5...size.width * 0.5),
        endY: startY + CGFloat.random(in: size.height * 0.2...size.height * 0.6),
        color: colors[index % colors.count],
        shapeKind: ConfettiShapeKind.allCases[index % ConfettiShapeKind.allCases.count],
        size: CGFloat.random(in: 5...10),
        rotation: Double.random(in: 0...720),
        delay: Double.random(in: 0...0.25)
      )
    }
  }
}

// MARK: - Particle Model

struct ConfettiParticle: Identifiable {
  let id: Int
  let startX: CGFloat
  let startY: CGFloat
  let endX: CGFloat
  let endY: CGFloat
  let color: Color
  let shapeKind: ConfettiShapeKind
  let size: CGFloat
  let rotation: Double
  let delay: Double
}

enum ConfettiShapeKind: CaseIterable {
  case circle
  case rectangle
  case roundedSquare
}

// MARK: - Individual Piece

private struct ConfettiPiece: View {
  let particle: ConfettiParticle
  let isAnimating: Bool

  var body: some View {
    pieceShape
      .rotationEffect(.degrees(isAnimating ? particle.rotation : 0))
      .position(
        x: isAnimating ? particle.endX : particle.startX,
        y: isAnimating ? particle.endY : particle.startY - 60
      )
      .opacity(isAnimating ? 0 : 1)
      .animation(
        .timingCurve(0.2, 0.8, 0.4, 1.0, duration: AppMotion.confettiDuration)
          .delay(particle.delay),
        value: isAnimating
      )
  }

  @ViewBuilder
  private var pieceShape: some View {
    switch particle.shapeKind {
    case .circle:
      Circle()
        .fill(particle.color)
        .frame(width: particle.size, height: particle.size)
    case .rectangle:
      Rectangle()
        .fill(particle.color)
        .frame(width: particle.size, height: particle.size * 0.4)
    case .roundedSquare:
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(particle.color)
        .frame(width: particle.size * 0.8, height: particle.size * 0.8)
    }
  }
}
