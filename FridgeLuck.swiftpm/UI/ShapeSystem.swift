import SwiftUI

// MARK: - Organic Blob

/// Soft, slightly irregular rounded shape for ingredient chips.
/// Deterministic but organic — seeded by a hash value so each instance is unique but stable.
struct FLOrganicBlob: Shape {
  let seed: Int

  func path(in rect: CGRect) -> Path {
    let cx = Double(rect.midX)
    let cy = Double(rect.midY)
    let rx = Double(rect.width) * 0.5
    let ry = Double(rect.height) * 0.5
    let points = 8
    var path = Path()

    for i in 0..<points {
      let angle = (Double(i) / Double(points)) * .pi * 2 - .pi / 2
      let wobble = seededRandom(seed: seed, index: i)
      let radiusX = rx * (0.88 + wobble * 0.18)
      let radiusY = ry * (0.88 + wobble * 0.18)
      let x = cx + cos(angle) * radiusX
      let y = cy + sin(angle) * radiusY

      if i == 0 {
        path.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
      } else {
        let prevAngle = (Double(i - 1) / Double(points)) * .pi * 2 - .pi / 2

        let midAngle = (prevAngle + angle) / 2
        let controlWobble = seededRandom(seed: seed, index: i + points)
        let controlR = max(rx, ry) * (1.02 + controlWobble * 0.08)
        let cpX = cx + cos(midAngle) * controlR
        let cpY = cy + sin(midAngle) * controlR

        path.addQuadCurve(
          to: CGPoint(x: CGFloat(x), y: CGFloat(y)),
          control: CGPoint(x: CGFloat(cpX), y: CGFloat(cpY))
        )
      }
    }

    // Close with a curve back to start
    let firstAngle = -Double.pi / 2
    let firstWobble = seededRandom(seed: seed, index: 0)
    let firstX = cx + cos(firstAngle) * rx * (0.88 + firstWobble * 0.18)
    let firstY = cy + sin(firstAngle) * ry * (0.88 + firstWobble * 0.18)
    let lastAngle = (Double(points - 1) / Double(points)) * .pi * 2 - .pi / 2
    let closeAngle = (lastAngle + firstAngle + .pi * 2) / 2
    let closeWobble = seededRandom(seed: seed, index: points * 2)
    let closeR = max(rx, ry) * (1.02 + closeWobble * 0.08)
    path.addQuadCurve(
      to: CGPoint(x: CGFloat(firstX), y: CGFloat(firstY)),
      control: CGPoint(
        x: CGFloat(cx + cos(closeAngle) * closeR),
        y: CGFloat(cy + sin(closeAngle) * closeR)
      )
    )

    return path
  }

  private func seededRandom(seed: Int, index: Int) -> Double {
    var h = UInt64(bitPattern: Int64(seed &* 374_761_393 &+ index &* 668_265_263))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return Double(h % 1000) / 1000.0
  }
}

// MARK: - Wave Divider

/// Horizontal wave separator between sections. Replaces flat Rectangle dividers.
struct FLWaveDivider: View {
  var color: Color = AppTheme.oat.opacity(0.30)
  var amplitude: CGFloat = 4
  var frequency: CGFloat = 2.5

  var body: some View {
    WaveShape(amplitude: amplitude, frequency: frequency)
      .stroke(color, lineWidth: 1)
      .frame(height: amplitude * 2 + 2)
  }
}

private struct WaveShape: Shape {
  let amplitude: CGFloat
  let frequency: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let midY = rect.midY
    let step: CGFloat = 2

    path.move(to: CGPoint(x: 0, y: midY))

    var x: CGFloat = step
    while x <= rect.width {
      let relativeX = x / rect.width
      let y = midY + sin(relativeX * .pi * 2 * frequency) * amplitude
      path.addLine(to: CGPoint(x: x, y: y))
      x += step
    }

    return path
  }
}

// MARK: - Arc Indicator

/// Arc-based progress indicator. Used for scan stages and onboarding progress.
struct FLArcIndicator: View {
  let progress: Double  // 0.0 to 1.0
  let steps: Int
  var trackColor: Color = AppTheme.oat.opacity(0.25)
  var fillColor: Color = AppTheme.accent
  var size: CGFloat = 48

  var body: some View {
    ZStack {
      // Track arc
      ArcShape()
        .stroke(trackColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))

      // Fill arc
      ArcShape()
        .trim(from: 0, to: progress)
        .stroke(fillColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))

      // Step dots
      ForEach(0..<steps, id: \.self) { step in
        let angle = stepAngle(step: step)
        let active = Double(step + 1) / Double(steps) <= progress + 0.01
        let radius = size / 2 - 2
        Circle()
          .fill(active ? fillColor : trackColor)
          .frame(width: active ? 8 : 6, height: active ? 8 : 6)
          .offset(
            x: cos(angle) * radius,
            y: sin(angle) * radius
          )
      }
    }
    .frame(width: size, height: size * 0.6)
  }

  private func stepAngle(step: Int) -> CGFloat {
    let startAngle = CGFloat.pi  // left
    let endAngle: CGFloat = 0  // right
    let fraction = CGFloat(step) / CGFloat(max(1, steps - 1))
    return startAngle + (endAngle - startAngle) * fraction
  }
}

private struct ArcShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { p in
      p.addArc(
        center: CGPoint(x: rect.midX, y: rect.maxY),
        radius: min(rect.width, rect.height * 2) / 2,
        startAngle: .degrees(180),
        endAngle: .degrees(0),
        clockwise: false
      )
    }
  }
}

// MARK: - Torn Edge

/// Torn paper effect for card tops or bottoms — a one-sided ragged edge via Path.
struct FLTornEdge: Shape {
  var seed: Int = 42
  var teethCount: Int = 24

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let step = rect.width / CGFloat(teethCount)

    path.move(to: CGPoint(x: 0, y: 0))

    for i in 0...teethCount {
      let x = CGFloat(i) * step
      let wobble = tornRandom(seed: seed, index: i)
      let y = wobble * 6
      path.addLine(to: CGPoint(x: x, y: y))
    }

    path.addLine(to: CGPoint(x: rect.width, y: rect.height))
    path.addLine(to: CGPoint(x: 0, y: rect.height))
    path.closeSubpath()
    return path
  }

  private func tornRandom(seed: Int, index: Int) -> CGFloat {
    var h = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ index &* 340_573_321))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return CGFloat(h % 1000) / 1000.0
  }
}

// MARK: - Diagonal Clip

/// Angled clip for hero sections — the "magazine cut" feel.
struct FLDiagonalClip: Shape {
  var cutHeight: CGFloat = 40

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: rect.width, y: 0))
    path.addLine(to: CGPoint(x: rect.width, y: rect.height - cutHeight))
    path.addLine(to: CGPoint(x: 0, y: rect.height))
    path.closeSubpath()
    return path
  }
}
