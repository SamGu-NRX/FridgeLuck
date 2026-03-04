import SwiftUI

// MARK: - Overlay

struct SpotlightTutorialOverlay: View {
  let steps: [SpotlightStep]
  let anchors: [String: CGRect]
  @Binding var isPresented: Bool
  var onScrollToAnchor: ((String) -> Void)? = nil
  var onStepChange: ((SpotlightStep) -> Void)? = nil

  @State private var stepIndex = 0
  @State private var appeared = false
  @State private var highlightGlow: CGFloat = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: SpotlightStep { steps[stepIndex] }
  private var isLast: Bool { stepIndex >= steps.count - 1 }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        dimmingLayer(in: geo)
          .zIndex(0)
        highlightBorder(in: geo)
          .zIndex(1)
        skipButton(in: geo)
          .zIndex(2)
        tooltipCard(in: geo)
          .zIndex(3)
      }
    }
    .ignoresSafeArea()
    .opacity(appeared ? 1 : 0)
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
        appeared = true
      }
      onStepChange?(step)
      if let anchorID = steps[0].anchorID {
        onScrollToAnchor?(anchorID)
      }
    }
    .onChange(of: stepIndex) {
      onStepChange?(step)
    }
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - Dimming

  @ViewBuilder
  private func dimmingLayer(in geo: GeometryProxy) -> some View {
    if let rect = highlightRect(in: geo) {
      let highlight = highlightMetrics(for: rect)
      Color.black.opacity(0.68)
        .reverseMask {
          RoundedRectangle(cornerRadius: highlight.cornerRadius, style: .continuous)
            .frame(width: highlight.width, height: highlight.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .animation(
          reduceMotion ? nil : AppMotion.spotlightMove,
          value: stepIndex
        )
    } else {
      Color.black.opacity(0.72)
    }
  }

  @ViewBuilder
  private func highlightBorder(in geo: GeometryProxy) -> some View {
    if let rect = highlightRect(in: geo) {
      let highlight = highlightMetrics(for: rect)
      RoundedRectangle(cornerRadius: highlight.cornerRadius, style: .continuous)
        .stroke(.white.opacity(0.22 + highlightGlow * 0.35), lineWidth: 1.5 + highlightGlow * 1.5)
        .frame(width: highlight.width, height: highlight.height)
        .position(x: rect.midX, y: rect.midY)
        .animation(
          reduceMotion ? nil : AppMotion.spotlightMove,
          value: stepIndex
        )
    }
  }

  // MARK: - Tooltip

  private func tooltipCard(in geo: GeometryProxy) -> some View {
    let y = tooltipY(in: geo, screenHeight: screenHeight(for: geo))

    return VStack(spacing: AppTheme.Space.md) {
      Image(systemName: step.icon)
        .contentTransition(.symbolEffect(.replace))
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(AppTheme.accent.opacity(0.85), in: Circle())

      VStack(spacing: AppTheme.Space.xs) {
        Text(step.title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .contentTransition(.numericText())

        Text(step.message)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(.white.opacity(0.76))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.numericText())
      }

      HStack {
        stepIndicator
        Spacer()
        navButton
      }
      .padding(.top, AppTheme.Space.xxs)
    }
    .padding(AppTheme.Space.lg)
    .frame(maxWidth: min(geo.size.width - 48, 340))
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        .fill(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 15)
    .position(x: geo.size.width / 2, y: y)
    .animation(
      reduceMotion ? nil : AppMotion.spotlightMove,
      value: stepIndex
    )
  }

  private var stepIndicator: some View {
    HStack(spacing: 5) {
      ForEach(0..<steps.count, id: \.self) { i in
        Capsule()
          .fill(i == stepIndex ? Color.white : Color.white.opacity(0.28))
          .frame(width: i == stepIndex ? 18 : 6, height: 6)
          .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78),
            value: stepIndex
          )
      }
    }
  }

  @ViewBuilder
  private var navButton: some View {
    if isLast {
      Button {
        dismissOverlay()
      } label: {
        Text("Let\u{2019}s go")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .background(.white, in: Capsule())
      }
      .buttonStyle(SpotlightPressStyle())
    } else {
      Button {
        advance()
      } label: {
        HStack(spacing: 4) {
          Text("Next")
          Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.16), in: Capsule())
      }
      .buttonStyle(SpotlightPressStyle())
    }
  }

  // MARK: - Skip

  private func skipButton(in geo: GeometryProxy) -> some View {
    VStack {
      Spacer()
      HStack {
        skipButtonLabel
        Spacer()
      }
      .padding(.bottom, geo.safeAreaInsets.bottom + skipBottomOffset)
      .padding(.horizontal, skipHorizontalPadding)
    }
  }

  private var skipButtonLabel: some View {
    Button {
      dismissOverlay()
    } label: {
      HStack(spacing: AppTheme.Space.xxs) {
        Text("Skip tour")
          .font(.system(size: 14, weight: .medium))
        Image(systemName: "forward.fill")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(.white.opacity(0.70))
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.white.opacity(0.12), in: Capsule())
      .overlay(
        Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
      )
    }
    .buttonStyle(SpotlightPressStyle())
    .accessibilityLabel("Skip guided tour")
  }

  // MARK: - Positioning

  private let tooltipCardHeight: CGFloat = 260
  private let skipBottomOffset: CGFloat = 24
  private let skipHorizontalPadding: CGFloat = AppTheme.Space.page

  private struct HighlightMetrics {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
  }

  private func highlightRect(in geo: GeometryProxy) -> CGRect? {
    guard let anchorID = step.anchorID, let globalRect = anchors[anchorID] else { return nil }

    let overlayFrame = geo.frame(in: .global)
    let normalizedRect = CGRect(
      x: globalRect.minX - overlayFrame.minX,
      y: globalRect.minY - overlayFrame.minY,
      width: globalRect.width,
      height: globalRect.height
    )

    let visibleBounds = CGRect(
      x: 0,
      y: 0,
      width: geo.size.width,
      height: screenHeight(for: geo)
    ).insetBy(dx: -24, dy: -24)

    let normalizedScore = visibleIntersectionArea(of: normalizedRect, within: visibleBounds)
    let globalScore = visibleIntersectionArea(of: globalRect, within: visibleBounds)

    return globalScore > normalizedScore ? globalRect : normalizedRect
  }

  private func visibleIntersectionArea(of rect: CGRect, within bounds: CGRect) -> CGFloat {
    guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
      return 0
    }
    let intersection = rect.intersection(bounds)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    return intersection.width * intersection.height
  }

  private func highlightMetrics(for rect: CGRect) -> HighlightMetrics {
    switch step.anchorID {
    case "toolbarAdd":
      return HighlightMetrics(
        width: max(rect.width + 16, 72),
        height: max(rect.height + 12, 38),
        cornerRadius: 10
      )
    case "swapButton":
      return HighlightMetrics(
        width: max(rect.width + 18, 58),
        height: max(rect.height + 14, 38),
        cornerRadius: 12
      )
    default:
      return HighlightMetrics(
        width: rect.width + 20,
        height: rect.height + 20,
        cornerRadius: 14
      )
    }
  }

  private func tooltipY(in geo: GeometryProxy, screenHeight: CGFloat) -> CGFloat {
    let centeredY = clampedTooltipY(screenHeight / 2, screenHeight: screenHeight)
    guard let rect = highlightRect(in: geo) else {
      return centeredY
    }
    let gap: CGFloat = 24
    let below = rect.maxY + gap + tooltipCardHeight / 2
    let above = rect.minY - gap - tooltipCardHeight / 2

    if below + tooltipCardHeight / 2 < screenHeight - 40 {
      return clampedTooltipY(below, screenHeight: screenHeight)
    }
    if above - tooltipCardHeight / 2 > 40 {
      return clampedTooltipY(above, screenHeight: screenHeight)
    }
    return centeredY
  }

  private func clampedTooltipY(_ y: CGFloat, screenHeight: CGFloat) -> CGFloat {
    let inset: CGFloat = 40
    let halfHeight = tooltipCardHeight / 2
    let minCenter = inset + halfHeight
    let maxCenter = screenHeight - inset - halfHeight

    guard maxCenter > minCenter else {
      return max(halfHeight, min(screenHeight - halfHeight, y))
    }
    return min(max(y, minCenter), maxCenter)
  }

  private func screenHeight(for geo: GeometryProxy) -> CGFloat {
    let overlayTop = geo.frame(in: .global).minY
    return max(geo.size.height, UIScreen.main.bounds.height - overlayTop)
  }

  // MARK: - Actions

  private func advance() {
    guard !isLast else {
      dismissOverlay()
      return
    }
    let nextIndex = stepIndex + 1
    let needsScroll = steps[nextIndex].anchorID != nil

    if let anchorID = steps[nextIndex].anchorID {
      onScrollToAnchor?(anchorID)
    }

    let stepDelay: Double = needsScroll && !reduceMotion ? 0.25 : 0

    DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay) {
      withAnimation(self.reduceMotion ? nil : AppMotion.spotlightMove) {
        self.stepIndex = nextIndex
      }
      if !self.reduceMotion {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
          self.highlightGlow = 1
          withAnimation(.easeOut(duration: 0.5)) { self.highlightGlow = 0 }
        }
      }
    }
  }

  private func dismissOverlay() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
      appeared = false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
      isPresented = false
    }
  }
}

// MARK: - Supporting

private struct SpotlightPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .opacity(configuration.isPressed ? 0.85 : 1.0)
      .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

// MARK: - Reverse Mask

extension View {
  fileprivate func reverseMask<M: View>(@ViewBuilder _ content: () -> M) -> some View {
    mask {
      Rectangle()
        .ignoresSafeArea()
        .overlay { content().blendMode(.destinationOut) }
    }
  }
}
