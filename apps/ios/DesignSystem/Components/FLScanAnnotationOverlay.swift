import SwiftUI

/// Ingredient pins on a scan photo, using normalized Vision bounding boxes flipped into SwiftUI space.
struct FLScanAnnotationOverlay: View {
  let image: UIImage
  let detections: [Detection]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visibleCount = 0

  private var annotated: [Detection] {
    Array(detections.filter { $0.normalizedBoundingBox != nil }.prefix(8))
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: geo.size.width, height: geo.size.height)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))

        LinearGradient(
          colors: [.clear, Color.black.opacity(0.3)],
          startPoint: .center,
          endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))

        ForEach(Array(annotated.enumerated()), id: \.element.id) { index, detection in
          if index < visibleCount, let bbox = detection.normalizedBoundingBox {
            AnnotationPin(
              label: detection.label,
              normalizedCenter: CGPoint(
                x: bbox.midX,
                y: 1.0 - bbox.midY
              ),
              containerSize: geo.size
            )
            .transition(
              .asymmetric(
                insertion: .scale(scale: 0.5, anchor: .center)
                  .combined(with: .opacity),
                removal: .opacity
              ))
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
    .onAppear {
      guard !annotated.isEmpty else { return }
      if reduceMotion {
        visibleCount = annotated.count
      } else {
        animateIn()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Scanned photo with \(annotated.count) detected ingredient\(annotated.count == 1 ? "" : "s")"
    )
  }

  private func animateIn() {
    for i in 0..<annotated.count {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.12) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
          visibleCount = i + 1
        }
      }
    }
  }
}

// MARK: - Annotation Pin

private struct AnnotationPin: View {
  let label: String
  let normalizedCenter: CGPoint
  let containerSize: CGSize

  private var dotPos: CGPoint {
    CGPoint(
      x: normalizedCenter.x * containerSize.width,
      y: normalizedCenter.y * containerSize.height
    )
  }

  private var labelOffset: CGPoint {
    let dx: CGFloat = normalizedCenter.x > 0.5 ? -56 : 56
    let dy: CGFloat = normalizedCenter.y > 0.5 ? -32 : 32
    return CGPoint(x: dotPos.x + dx, y: dotPos.y + dy)
  }

  var body: some View {
    ZStack {
      Path { path in
        path.move(to: dotPos)
        path.addLine(to: labelOffset)
      }
      .stroke(Color.white.opacity(0.6), lineWidth: 1)

      Circle()
        .fill(Color.white)
        .frame(width: 8, height: 8)
        .overlay(
          Circle()
            .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
            .frame(width: 14, height: 14)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 1)
        .position(dotPos)

      Text(label)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Capsule()
            .fill(Color.black.opacity(0.55))
            .overlay(
              Capsule()
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
        )
        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        .position(labelOffset)
    }
  }
}
