import SwiftUI

/// Corner-bracket viewfinder overlay with optional breathing animation.
struct FLViewfinderFrame: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isBreathing = false

  private let bracketLength: CGFloat = 32
  private let strokeWidth: CGFloat = 3
  private let cornerRadius: CGFloat = 4
  private let color = Color.white.opacity(0.90)

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height

      ZStack {
        cornerBracket(at: .topLeading, width: w, height: h)
        cornerBracket(at: .topTrailing, width: w, height: h)
        cornerBracket(at: .bottomLeading, width: w, height: h)
        cornerBracket(at: .bottomTrailing, width: w, height: h)
      }
      .scaleEffect(reduceMotion ? 1.0 : (isBreathing ? 1.015 : 1.0))
      .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(
        AppMotion.viewfinderBreathing.repeatForever(autoreverses: true)
      ) {
        isBreathing = true
      }
    }
  }

  // MARK: - Corner Bracket

  @ViewBuilder
  private func cornerBracket(
    at alignment: Alignment,
    width: CGFloat,
    height: CGFloat
  ) -> some View {
    let path = bracketPath(for: alignment)

    path
      .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
      .frame(width: width, height: height)
  }

  private func bracketPath(for alignment: Alignment) -> Path {
    Path { path in
      switch alignment {
      case .topLeading:
        path.move(to: CGPoint(x: 0, y: bracketLength))
        path.addLine(to: CGPoint(x: 0, y: cornerRadius))
        path.addQuadCurve(
          to: CGPoint(x: cornerRadius, y: 0),
          control: CGPoint(x: 0, y: 0)
        )
        path.addLine(to: CGPoint(x: bracketLength, y: 0))

      case .topTrailing:
        path.move(to: CGPoint(x: -bracketLength, y: 0))
        path.addLine(to: CGPoint(x: -cornerRadius, y: 0))
        path.addQuadCurve(
          to: CGPoint(x: 0, y: cornerRadius),
          control: CGPoint(x: 0, y: 0)
        )
        path.addLine(to: CGPoint(x: 0, y: bracketLength))

      case .bottomLeading:
        path.move(to: CGPoint(x: bracketLength, y: 0))
        path.addLine(to: CGPoint(x: cornerRadius, y: 0))
        path.addQuadCurve(
          to: CGPoint(x: 0, y: -cornerRadius),
          control: CGPoint(x: 0, y: 0)
        )
        path.addLine(to: CGPoint(x: 0, y: -bracketLength))

      case .bottomTrailing:
        path.move(to: CGPoint(x: 0, y: -bracketLength))
        path.addLine(to: CGPoint(x: 0, y: -cornerRadius))
        path.addQuadCurve(
          to: CGPoint(x: -cornerRadius, y: 0),
          control: CGPoint(x: 0, y: 0)
        )
        path.addLine(to: CGPoint(x: -bracketLength, y: 0))

      default:
        break
      }
    }
  }
}
