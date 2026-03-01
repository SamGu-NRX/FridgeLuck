import SwiftUI

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
        "This guided tour walks you through the app. In a few quick steps, you\u{2019}ll set up your profile, explore pre-built demos, and unlock your personalized dashboard."
    ),
    SpotlightStep(
      id: "setup",
      anchorID: "progressView",
      icon: "rectangle.stack",
      title: "Your Guided Tour",
      message:
        "These 4 steps each teach a core feature. Complete them all to unlock your full dashboard \u{2014} or skip ahead any time."
    ),
    SpotlightStep(
      id: "personalize",
      anchorID: "quest_0",
      icon: "person.crop.circle.badge.checkmark",
      title: "Set Up Your Profile",
      message:
        "This is your onboarding \u{2014} tell me your goals, dietary needs, and allergens. I\u{2019}ll personalize every recipe to fit your life."
    ),
    SpotlightStep(
      id: "demos",
      anchorID: "quest_1",
      icon: "play.rectangle.fill",
      title: "Pre-built Demos",
      message:
        "Setting up a live fridge scan in Xcode isn\u{2019}t practical, so we\u{2019}ve pre-built demo scenarios for you. Pick a pre-stocked fridge, cook a recipe, and see the full experience."
    ),
    SpotlightStep(
      id: "wrapup",
      anchorID: nil,
      icon: "arrow.right.circle",
      title: "Before You Begin",
      message:
        "Want to redo this tour later? Scroll to the bottom and tap \u{201C}Reset progress\u{201D} to start fresh. Or skip the tour entirely \u{2014} you\u{2019}ll still have full access to demo mode from the main dashboard."
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

  @State private var stepIndex = 0
  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: SpotlightStep { steps[stepIndex] }
  private var isLast: Bool { stepIndex >= steps.count - 1 }

  private var highlightRect: CGRect? {
    guard let aid = step.anchorID else { return nil }
    return anchors[aid]
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        dimmingLayer
        highlightBorder
        tooltipCard(in: geo)
        skipButton(in: geo)
      }
    }
    .ignoresSafeArea()
    .opacity(appeared ? 1 : 0)
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
        appeared = true
      }
      if let anchorID = steps[0].anchorID {
        onScrollToAnchor?(anchorID)
      }
    }
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - Dimming

  @ViewBuilder
  private var dimmingLayer: some View {
    let pad: CGFloat = 10
    let cr: CGFloat = 14

    if let rect = highlightRect {
      Color.black.opacity(0.68)
        .reverseMask {
          RoundedRectangle(cornerRadius: cr, style: .continuous)
            .frame(width: rect.width + pad * 2, height: rect.height + pad * 2)
            .position(x: rect.midX, y: rect.midY)
        }
        .animation(
          reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
          value: stepIndex
        )
    } else {
      Color.black.opacity(0.72)
    }
  }

  @ViewBuilder
  private var highlightBorder: some View {
    if let rect = highlightRect {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.white.opacity(0.22), lineWidth: 1.5)
        .frame(width: rect.width + 20, height: rect.height + 20)
        .position(x: rect.midX, y: rect.midY)
        .animation(
          reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
          value: stepIndex
        )
    }
  }

  // MARK: - Tooltip

  private func tooltipCard(in geo: GeometryProxy) -> some View {
    let screenH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
    let y = tooltipY(screenHeight: screenH)

    return VStack(spacing: AppTheme.Space.md) {
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
      reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
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
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75),
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
      .buttonStyle(.plain)
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
      .buttonStyle(.plain)
    }
  }

  // MARK: - Skip

  private func skipButton(in geo: GeometryProxy) -> some View {
    VStack {
      HStack {
        Spacer()
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
        .buttonStyle(.plain)
        .accessibilityLabel("Skip guided tour")
      }
      .padding(.top, geo.safeAreaInsets.top + 50)
      .padding(.trailing, AppTheme.Space.page)
      Spacer()
    }
  }

  // MARK: - Positioning

  private func tooltipY(screenHeight: CGFloat) -> CGFloat {
    guard let rect = highlightRect else {
      return screenHeight / 2
    }
    let cardH: CGFloat = 260
    let gap: CGFloat = 24
    let below = rect.maxY + gap + cardH / 2
    let above = rect.minY - gap - cardH / 2

    if below + cardH / 2 < screenHeight - 40 { return below }
    if above - cardH / 2 > 40 { return above }
    return screenHeight / 2
  }

  // MARK: - Actions

  private func advance() {
    guard !isLast else {
      dismissOverlay()
      return
    }
    let nextIndex = stepIndex + 1
    if let anchorID = steps[nextIndex].anchorID {
      onScrollToAnchor?(anchorID)
    }
    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) {
      stepIndex = nextIndex
    }
  }

  private func dismissOverlay() {
    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) {
      appeared = false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
      isPresented = false
    }
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
