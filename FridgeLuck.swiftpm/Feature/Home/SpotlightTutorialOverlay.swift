import SwiftUI
import UIKit

// MARK: - Step Model

struct SpotlightStep: Identifiable {
  let id: String
  let anchorID: String?
  let icon: String
  let title: String
  let message: String
}

extension SpotlightStep {
  static let onboarding: [SpotlightStep] = [
    SpotlightStep(
      id: "welcome",
      anchorID: nil,
      icon: "sparkles",
      title: "Welcome to FridgeLuck",
      message:
        "This guided tour teaches the app itself. You already handled setup before entering \u{2014} now we\u{2019}ll show you where everything lives."
    ),
    SpotlightStep(
      id: "setup",
      anchorID: "progressView",
      icon: "rectangle.stack",
      title: "Your Guided Tour",
      message:
        "These 5 steps unlock one at a time: start with a demo scan, review uncertain ingredients, choose a recipe match, learn the live guide, then cook."
    ),
    SpotlightStep(
      id: "scan_first",
      anchorID: "quest_0",
      icon: "camera.viewfinder",
      title: "Start With Demo Mode",
      message:
        "Use the demo scenarios first. They make it easy to understand the full scan-to-recipe loop before you use your own kitchen."
    ),
    SpotlightStep(
      id: "wrapup",
      anchorID: nil,
      icon: "arrow.right.circle",
      title: "Before You Begin",
      message:
        "After your demo scan, FridgeLuck will meet you inside ingredient review for the next lesson. Want to redo this tour later? Scroll to the bottom and tap \u{201C}Reset progress\u{201D}."
    ),
  ]

  static let completion: [SpotlightStep] = [
    SpotlightStep(
      id: "congrats",
      anchorID: nil,
      icon: "party.popper.fill",
      title: "Setup Complete!",
      message:
        "You\u{2019}ve finished the guided tour. Your personalized kitchen dashboard is now fully unlocked."
    ),
    SpotlightStep(
      id: "rhythm",
      anchorID: "myRhythm",
      icon: "book.closed.fill",
      title: "My Rhythm",
      message:
        "This is your cooking journal at a glance. Your latest recipes and cooking history live here \u{2014} tap through to view your full recipe book."
    ),
    SpotlightStep(
      id: "explore_done",
      anchorID: nil,
      icon: "checkmark.seal.fill",
      title: "You\u{2019}re All Set",
      message:
        "Use the scan button to photograph your fridge, try demo scenarios, or open Dashboard for full analytics. Happy cooking!"
    ),
  ]

  static let ingredientReview: [SpotlightStep] = [
    SpotlightStep(
      id: "review_welcome",
      anchorID: nil,
      icon: "eyes.inverse",
      title: "Review Your Ingredients",
      message:
        "This page shows everything the scan detected. Items are sorted by confidence \u{2014} review uncertain ones before finding recipes."
    ),
    SpotlightStep(
      id: "review_confidence",
      anchorID: "confidenceLevels",
      icon: "gauge.with.dots.needle.33percent",
      title: "Confidence Levels",
      message:
        "Auto = high confidence (auto-selected). Confirm = medium confidence (pick the right match). Maybe = low confidence (tap to include)."
    ),
    SpotlightStep(
      id: "review_auto",
      anchorID: "autoDetected",
      icon: "checkmark.seal.fill",
      title: "Auto-Detected Items",
      message:
        "These ingredients were detected with high confidence and are already selected. Tap any chip to deselect it, or tap the \u{24D8} icon to view nutrition details."
    ),
    SpotlightStep(
      id: "review_confirm",
      anchorID: "needsConfirmation",
      icon: "questionmark.circle.fill",
      title: "Needs Confirmation",
      message:
        "These items need your help. Pick the correct match from the options, tap \u{201C}Choose another\u{201D} to search, or \u{201C}Not this item\u{201D} to skip."
    ),
    SpotlightStep(
      id: "review_bulk",
      anchorID: "bulkActions",
      icon: "checklist",
      title: "Quick Actions & Add",
      message:
        "\u{201C}Select Auto\u{201D} accepts all high-confidence items at once. \u{201C}Clear Uncertain\u{201D} resets your choices. The \u{201C}+ Add\u{201D} button lets you manually add ingredients the scan missed."
    ),
    SpotlightStep(
      id: "review_toolbar_add",
      anchorID: "toolbarAdd",
      icon: "plus.circle.fill",
      title: "Toolbar Add Button",
      message:
        "You can also add ingredients from the toolbar \u{2014} same action, always accessible regardless of scroll position."
    ),
    SpotlightStep(
      id: "review_find_recipes",
      anchorID: "findRecipes",
      icon: "fork.knife",
      title: "Find Recipes",
      message:
        "When you\u{2019}re happy with your selection, tap this button. The count updates as you toggle ingredients \u{2014} aim for at least 3\u{2013}5 for better recipe matches."
    ),
  ]

  static let demoMode: [SpotlightStep] = [
    SpotlightStep(
      id: "demo_welcome",
      anchorID: nil,
      icon: "play.rectangle.fill",
      title: "Welcome to Demo Mode",
      message:
        "Each card is a different fridge scenario with real ingredients. Pick one to see how FridgeLuck scans and finds recipes."
    ),
    SpotlightStep(
      id: "demo_scenarios",
      anchorID: "scenarioGrid",
      icon: "square.grid.2x2.fill",
      title: "Pick a Scenario",
      message:
        "Tap any card to preview what\u{2019}s inside, then scan it. Everything here is safe to explore \u{2014} try as many as you like."
    ),
  ]

  static let swapIngredients: [SpotlightStep] = [
    SpotlightStep(
      id: "swap_intro",
      anchorID: "swapButton",
      icon: "arrow.triangle.swap",
      title: "Swap Ingredients",
      message:
        "Tap this swap button to open substitutions. Great for dietary needs, allergies, or using what you already have."
    )
  ]

  static let liveAssistantLesson: [SpotlightStep] = [
    SpotlightStep(
      id: "live_lesson_intro",
      anchorID: nil,
      icon: "sparkles.rectangle.stack.fill",
      title: "Your Recipe Match Is Ready",
      message:
        "Before you start cooking, FridgeLuck can turn that recipe into a hands-free kitchen guide from Home."
    ),
    SpotlightStep(
      id: "live_lesson_entry",
      anchorID: "liveAssistantEntry",
      icon: "waveform.and.mic",
      title: "Set Up The Live Guide",
      message:
        "Place the phone on a counter stand near your prep area so Gemini can see your cutting board, ingredients, and pan while it guides you."
    ),
    SpotlightStep(
      id: "live_lesson_grounding",
      anchorID: nil,
      icon: "checkmark.shield.fill",
      title: "Stay Grounded",
      message:
        "Use the assistant for step-by-step coaching, substitutions, and food-safety checks. You can skip this lesson now and reopen it from Home later."
    ),
  ]
}

// MARK: - Coordinator

/// Bridges spotlight state between HomeDashboardView (which owns the logic) and
/// ContentView (which presents the overlay above the tab bar).
@Observable
final class SpotlightCoordinator {
  var activeSteps: [SpotlightStep]? = nil
  var anchors: [String: CGRect] = [:]
  var onScrollToAnchor: ((String) -> Void)? = nil
}

// MARK: - Preference Key

struct SpotlightAnchorKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

extension View {
  func spotlightAnchor(_ id: String) -> some View {
    background(
      GeometryReader { geo in
        Color.clear.preference(
          key: SpotlightAnchorKey.self,
          value: [id: geo.frame(in: .global)]
        )
      }
    )
  }
}

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
    let sceneScreenHeight =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })?
      .screen
      .bounds.height
      ?? geo.size.height

    return max(geo.size.height, sceneScreenHeight - overlayTop)
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
