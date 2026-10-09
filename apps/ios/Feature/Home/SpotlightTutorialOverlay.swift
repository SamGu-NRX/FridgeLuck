import SwiftUI
import UIKit

// MARK: - Overlay

struct SpotlightTutorialOverlay: View {
  let presentationID: UUID
  let steps: [SpotlightStep]
  let anchors: [String: CGRect]
  @Binding var isPresented: Bool
  var onScrollToAnchor: ((String) -> Void)? = nil
  var onStepChange: ((SpotlightStep) -> Void)? = nil

  @State private var stepIndex = 0
  @State private var appeared = false
  @State private var highlightGlow: CGFloat = 0
  @State private var transitionTask: Task<Void, Never>?
  @State private var dismissTask: Task<Void, Never>?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: SpotlightStep { steps[stepIndex] }
  private var isFirst: Bool { stepIndex <= 0 }
  private var isLast: Bool { SpotlightTourProgress.isLastStep(stepIndex, of: steps.count) }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        dimmingLayer(in: geo)
          .zIndex(0)
        highlightBorder(in: geo)
          .zIndex(1)
        tooltipCard(in: geo)
          .zIndex(2)
      }
    }
    .ignoresSafeArea()
    .opacity(appeared ? 1 : 0)
    .animation(reduceMotion ? nil : AppMotion.spotlightDimmer, value: appeared)
    .onAppear {
      guard !steps.isEmpty else {
        isPresented = false
        return
      }
      startEntrance()
      onStepChange?(step)
      if let anchorID = steps[0].anchorID {
        onScrollToAnchor?(anchorID)
      }
    }
    .onChange(of: stepIndex) {
      onStepChange?(step)
    }
    .onChange(of: presentationID) {
      cancelPendingTasks()
      stepIndex = 0
      appeared = false
      highlightGlow = 0
      startEntrance()
    }
    .onDisappear {
      cancelPendingTasks()
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
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: step.icon)
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 52, height: 52)
          .background(AppTheme.accent.opacity(0.85), in: Circle())

        VStack(spacing: AppTheme.Space.xs) {
          Text(step.title)
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)

          Text(step.message)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(.white.opacity(0.76))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .id(stepIndex)
      .transition(.blurReplace)

      controls
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
    .scaleEffect(appeared ? 1.0 : 0.96)
    .offset(y: appeared ? 0 : 8)
    .opacity(appeared ? 1 : 0)
    .animation(
      reduceMotion ? nil : AppMotion.spotlightMove,
      value: stepIndex
    )
    .animation(
      reduceMotion ? nil : AppMotion.spotlightCardEntry,
      value: appeared
    )
  }

  /// Skip lives in the card, not at a screen corner: on pushed screens a corner button sat
  /// inside the navigation bar, which took its taps (2026-10-07 walk, Review Ingredients).
  /// Skip holds the leading edge so it never moves as Back appears; Back sits beside Next.
  /// At large text sizes Skip drops below the row instead of squeezing it.
  private var controls: some View {
    VStack(spacing: AppTheme.Space.sm) {
      stepIndicator

      ViewThatFits(in: .horizontal) {
        HStack(spacing: AppTheme.Space.sm) {
          skipButton
          Spacer(minLength: 0)
          backButton
          navButton
        }

        VStack(spacing: AppTheme.Space.xs) {
          HStack(spacing: AppTheme.Space.sm) {
            backButton
            Spacer(minLength: 0)
            navButton
          }
          skipButton
        }
      }
    }
  }

  @ViewBuilder
  private var skipButton: some View {
    if SpotlightTourProgress.offersSkip(at: stepIndex, of: steps.count) {
      Button {
        dismissOverlay()
      } label: {
        Text("Skip tour")
          .font(AppTheme.Typography.bodyMedium.weight(.medium))
          .foregroundStyle(.white.opacity(0.70))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(SpotlightPressStyle())
      .transition(.opacity)
      .accessibilityLabel("Skip guided tour")
    }
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
  private var backButton: some View {
    if !isFirst {
      Button {
        goBack()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.65))
          .frame(width: 32, height: 32)
          .background(.white.opacity(0.10), in: Circle())
          .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
      }
      .buttonStyle(SpotlightPressStyle())
      .transition(
        .asymmetric(
          insertion: .scale(scale: 0.5).combined(with: .opacity),
          removal: .scale(scale: 0.85).combined(with: .opacity)
        )
      )
      .accessibilityLabel("Previous step")
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

  // MARK: - Positioning

  /// Estimated card height for placement. The step indicator's own row above the controls
  /// added 18 pt (6 pt dots + 12 pt spacing) to the earlier 260 pt estimate.
  private let tooltipCardHeight: CGFloat = 278
  private let scrollTransitionDelay: Duration = .milliseconds(250)
  private let highlightPulseDelay: Duration = .milliseconds(80)
  private let dismissDelay: Duration = .milliseconds(240)

  private struct HighlightMetrics {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
  }

  private func highlightRect(in geo: GeometryProxy) -> CGRect? {
    guard let anchorID = step.anchorID, let globalRect = anchors[anchorID] else { return nil }

    let overlayFrame = geo.frame(in: .global)
    return CGRect(
      x: globalRect.minX - overlayFrame.minX,
      y: globalRect.minY - overlayFrame.minY,
      width: globalRect.width,
      height: globalRect.height
    )
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
    let sceneScreenHeight =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })?
      .screen
      .bounds.height
      ?? geo.size.height

    return max(geo.size.height, sceneScreenHeight - overlayTop)
  }

  private func startEntrance() {
    guard !reduceMotion else {
      appeared = true
      return
    }

    Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled else { return }
      withAnimation(AppMotion.spotlightDimmer) {
        appeared = true
      }
    }
  }

  // MARK: - Actions

  private func goBack() {
    guard !isFirst else { return }
    let prevIndex = stepIndex - 1
    transitionToStep(at: prevIndex)
  }

  private func advance() {
    guard !isLast else {
      dismissOverlay()
      return
    }
    let nextIndex = stepIndex + 1
    transitionToStep(at: nextIndex)
  }

  private func dismissOverlay() {
    cancelPendingTasks()
    withAnimation(reduceMotion ? nil : AppMotion.spotlightDismiss) {
      appeared = false
    }
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: dismissDelay)
      guard !Task.isCancelled else { return }
      isPresented = false
    }
  }

  private func transitionToStep(at index: Int) {
    guard steps.indices.contains(index) else { return }

    dismissTask?.cancel()
    transitionTask?.cancel()

    let anchorID = steps[index].anchorID
    let needsScrollDelay = anchorID != nil && !reduceMotion

    if let anchorID {
      onScrollToAnchor?(anchorID)
    }

    transitionTask = Task { @MainActor in
      if needsScrollDelay {
        try? await Task.sleep(for: scrollTransitionDelay)
      }
      guard !Task.isCancelled else { return }

      withAnimation(reduceMotion ? nil : AppMotion.spotlightMove) {
        stepIndex = index
      }

      await pulseHighlightGlow()
    }
  }

  private func pulseHighlightGlow() async {
    guard !reduceMotion else { return }

    try? await Task.sleep(for: highlightPulseDelay)
    guard !Task.isCancelled else { return }

    highlightGlow = 1
    withAnimation(.easeOut(duration: 0.5)) {
      highlightGlow = 0
    }
  }

  private func cancelPendingTasks() {
    transitionTask?.cancel()
    dismissTask?.cancel()
    transitionTask = nil
    dismissTask = nil
  }
}

// MARK: - Tour Progress

/// Step rules the card's controls follow. The last step's "Let's go" ends the tour, so Skip is
/// offered on every step before it.
enum SpotlightTourProgress {
  static func isLastStep(_ index: Int, of count: Int) -> Bool {
    index >= count - 1
  }

  static func offersSkip(at index: Int, of count: Int) -> Bool {
    !isLastStep(index, of: count)
  }
}

// MARK: - Supporting

private struct SpotlightPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .pressFeedback(
        isPressed: configuration.isPressed, scale: 0.96, opacity: 0.85,
        animation: .spring(response: 0.2, dampingFraction: 0.7))
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
