import FLFeatureLogic
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ContentView")

// MARK: - Navigation Coordinator

/// Lightweight coordinator that allows deeply nested views (e.g. cooking celebration)
/// to signal the root ContentView to collapse the entire NavigationStack back to Home.
@Observable
final class NavigationCoordinator {
  var shouldReturnHome = false
  var didCompleteCooking = false

  func returnHome() {
    shouldReturnHome = true
  }

  /// Signal that the user finished the cooking celebration. ContentView will
  /// collapse the stack AND mark the cookAndRate quest as completed.
  func returnHomeAfterCooking() {
    didCompleteCooking = true
    shouldReturnHome = true
  }
}

// MARK: - App Tab

enum AppTab: Sendable {
  case home
  case dashboard
}

/// Root host view with permanent Home / Scan / Dashboard tab shell.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore

  @State private var selectedTab: AppTab = .home
  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToReverseScan = false
  @State private var navigateToDemoMode = false
  @State private var assistantRecipeContext: LiveAssistantRecipeContext?
  @State private var tutorialCookingRecipe: ScoredRecipe?
  @State private var showOnboarding = false
  @State private var showProfile = false
  @State private var navCoordinator = NavigationCoordinator()
  @State private var navAppeared = false
  @State private var spotlightCoordinator = SpotlightCoordinator()
  @State private var liveAssistantCoordinator = LiveAssistantCoordinator()

  // Scan mode menu state
  @State private var showScanModeMenu = false
  @State private var highlightedScanMode: ScanMode?

  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
  }

  private var dashboardNavRoute: DashboardEntryRoute {
    AppFlowPolicy.dashboardEntryRoute(
      hasOnboarded: hasOnboarded,
      isTutorialComplete: tutorialProgress.isComplete
    )
  }

  private var dashboardNavLabel: String {
    switch dashboardNavRoute {
    case .dashboard:
      return "Dashboard"
    case .profile:
      return "Profile"
    case .onboarding:
      return "Onboarding"
    }
  }

  private var dashboardNavIcon: String {
    switch dashboardNavRoute {
    case .dashboard:
      return "chart.bar.doc.horizontal.fill"
    case .profile:
      return "person.crop.circle.fill"
    case .onboarding:
      return "person.badge.plus"
    }
  }

  /// The shell nav should appear on top-level tab surfaces, not within pushed task flows.
  private var shouldShowBottomNav: Bool {
    switch selectedTab {
    case .home:
      return !navigateToScan && !navigateToReverseScan && !navigateToDemoMode
        && assistantRecipeContext == nil && tutorialCookingRecipe == nil
    case .dashboard:
      return true
    }
  }

  var body: some View {
    ZStack {
      NavigationStack {
        HomeDashboardView(
          deps: deps,
          onScan: openScan,
          onDemoMode: openDemoMode,
          onCompleteProfile: openProfileEditor,
          onOpenAssistant: openLiveAssistant,
          onOpenTutorialCook: openTutorialCook,
          onReset: performFullReset,
          spotlightCoordinator: spotlightCoordinator
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToScan) {
          ScanView()
        }
        .navigationDestination(isPresented: $navigateToReverseScan) {
          ReverseScanMealView()
        }
        .navigationDestination(isPresented: $navigateToDemoMode) {
          DemoModeView()
        }
        .navigationDestination(item: $assistantRecipeContext) { recipeContext in
          LiveAssistantView(
            recipeContext: recipeContext,
            onCompleteLesson: completeLiveAssistantLesson,
            onSkipLesson: completeLiveAssistantLesson
          )
        }
      }
      .environment(navCoordinator)
      .environment(liveAssistantCoordinator)
      .opacity(selectedTab == .home ? 1 : 0)
      .zIndex(selectedTab == .home ? 1 : 0)
      .allowsHitTesting(selectedTab == .home)

      if hasOnboarded && tutorialProgress.isComplete {
        NavigationStack {
          DashboardView(isTabEmbedded: true)
        }
        .environmentObject(deps)
        .opacity(selectedTab == .dashboard ? 1 : 0)
        .zIndex(selectedTab == .dashboard ? 1 : 0)
        .allowsHitTesting(selectedTab == .dashboard)
      }
    }
    .flPageBackground()
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if shouldShowBottomNav {
        bottomNav
          .opacity(navAppeared ? 1 : 0)
          .offset(y: navAppeared ? AppTheme.Home.navBaseOffset : AppTheme.Home.navBaseOffset + 20)
          .animation(reduceMotion ? nil : AppMotion.standard, value: navAppeared)
      }
    }
    .overlay {
      if let steps = spotlightCoordinator.activeSteps,
        selectedTab == .home, !navigateToScan, !navigateToReverseScan, !navigateToDemoMode,
        assistantRecipeContext == nil, tutorialCookingRecipe == nil
      {
        SpotlightTutorialOverlay(
          steps: steps,
          anchors: spotlightCoordinator.anchors,
          isPresented: Binding(
            get: { spotlightCoordinator.activeSteps != nil },
            set: { isPresented in
              if !isPresented {
                spotlightCoordinator.activeSteps = nil
              }
            }
          ),
          onScrollToAnchor: spotlightCoordinator.onScrollToAnchor
        )
        .ignoresSafeArea()
      }
    }
    .overlay {
      if shouldShowBottomNav {
        ScanModeMenu(
          isPresented: $showScanModeMenu,
          highlightedMode: $highlightedScanMode,
          onSelect: handleScanModeSelection
        )
      }
    }
    .onChange(of: navCoordinator.shouldReturnHome) { _, shouldReturn in
      guard shouldReturn else { return }

      if navCoordinator.didCompleteCooking {
        markTutorialQuest(.cookAndRate)
        navCoordinator.didCompleteCooking = false
      }

      navigateToScan = false
      navigateToReverseScan = false
      navigateToDemoMode = false
      assistantRecipeContext = nil
      tutorialCookingRecipe = nil
      selectedTab = .home
      navCoordinator.shouldReturnHome = false
    }
    .onChange(of: navigateToDemoMode) { wasNavigating, isNavigating in
      if wasNavigating && !isNavigating && !tutorialProgress.isCompleted(.firstScan) {
        markTutorialQuest(.firstScan)
      }
    }
    .task {
      await refreshOnboardingGate()
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingView(isRequired: !hasOnboarded) {
        firstRunExperienceStore.markCompletedCurrentVersion()
        hasOnboarded = true
        showOnboarding = false
        Task { await refreshOnboardingGate() }
      }
      .interactiveDismissDisabled(!hasOnboarded)
      .environmentObject(deps)
    }
    .sheet(isPresented: $showProfile) {
      ProfileView()
        .environmentObject(deps)
    }
    .fullScreenCover(item: $tutorialCookingRecipe) { recipe in
      CookingGuideView(scoredRecipe: recipe) {
        tutorialCookingRecipe = nil
        Task {
          try? await Task.sleep(for: .milliseconds(450))
          navCoordinator.returnHomeAfterCooking()
        }
      }
    }
    .onAppear {
      if reduceMotion {
        navAppeared = true
      } else if !navAppeared {
        withAnimation(AppMotion.standard.delay(0.22)) {
          navAppeared = true
        }
      }
    }
  }

  // MARK: - Scan Orb

  @State private var orbTouchDownDate: Date?
  @State private var orbLongPressTriggered = false
  private let orbLongPressThreshold: TimeInterval = 0.35

  private var scanOrb: some View {
    Image(systemName: "camera.fill")
      .font(.system(size: 22, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: AppTheme.Home.orbSize, height: AppTheme.Home.orbSize)
      .background(
        showScanModeMenu ? AppTheme.accent.opacity(0.75) : AppTheme.accent,
        in: Circle()
      )
      .overlay(Circle().stroke(AppTheme.surface.opacity(0.45), lineWidth: 1))
      .shadow(color: AppTheme.accent.opacity(0.34), radius: 18, x: 0, y: 8)
      .scaleEffect(showScanModeMenu ? 0.92 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: showScanModeMenu)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            // First touch — record start time
            if orbTouchDownDate == nil {
              orbTouchDownDate = value.time
              orbLongPressTriggered = false
            }

            let elapsed = value.time.timeIntervalSince(orbTouchDownDate ?? value.time)

            // Cross long-press threshold → enter drag-to-select mode
            if !orbLongPressTriggered && elapsed >= orbLongPressThreshold {
              orbLongPressTriggered = true
              let generator = UIImpactFeedbackGenerator(style: .medium)
              generator.impactOccurred()
              showScanModeMenu = true
            }

            // While in long-press mode, update drag highlight
            if orbLongPressTriggered {
              let newHighlight = ScanModeMenuGesture.highlightedMode(
                for: value.translation
              )
              if newHighlight != highlightedScanMode {
                highlightedScanMode = newHighlight
                if newHighlight != nil {
                  let generator = UISelectionFeedbackGenerator()
                  generator.selectionChanged()
                }
              }
            }
          }
          .onEnded { _ in
            let wasLongPress = orbLongPressTriggered

            if wasLongPress {
              // Long-press release — select highlighted mode if any
              if let mode = highlightedScanMode {
                showScanModeMenu = false
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                  handleScanModeSelection(mode)
                }
              }
              // If no mode highlighted, menu stays open for tap selection
            } else {
              // Quick tap — toggle menu
              if showScanModeMenu {
                showScanModeMenu = false
              } else {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                showScanModeMenu = true
              }
            }

            // Reset state
            orbTouchDownDate = nil
            orbLongPressTriggered = false
            highlightedScanMode = nil
          }
      )
  }

  // MARK: - Scan Mode Selection

  private func handleScanModeSelection(_ mode: ScanMode) {
    switch mode {
    case .scanIngredients:
      openScan()
    case .updateGroceries:
      // TODO: Route to grocery/pantry management view
      logger.info("Update Groceries selected — feature coming soon")
    case .logMeal:
      openReverseScan()
    }
  }

  // MARK: - Navigation Actions

  private func openScan() {
    switch AppFlowPolicy.scanEntryRoute(hasOnboarded: hasOnboarded) {
    case .scan:
      selectedTab = .home
      navigateToScan = true
    case .onboarding:
      showOnboarding = true
    }
  }

  private func openReverseScan() {
    switch AppFlowPolicy.scanEntryRoute(hasOnboarded: hasOnboarded) {
    case .scan:
      selectedTab = .home
      navigateToReverseScan = true
    case .onboarding:
      showOnboarding = true
    }
  }

  private func openDemoMode() {
    switch AppFlowPolicy.scanEntryRoute(hasOnboarded: hasOnboarded) {
    case .scan:
      selectedTab = .home
      navigateToDemoMode = true
    case .onboarding:
      showOnboarding = true
    }
  }

  private func openLiveAssistant() {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }
    guard let recipeContext = liveAssistantCoordinator.matchedRecipeContext else {
      logger.notice("Live assistant requested without a matched recipe context.")
      return
    }

    selectedTab = .home
    assistantRecipeContext = recipeContext
  }

  private func openTutorialCook() {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }
    guard let recipe = liveAssistantCoordinator.matchedRecipe else {
      logger.notice("Tutorial cook requested without a matched recipe.")
      return
    }

    selectedTab = .home
    tutorialCookingRecipe = recipe
  }

  private func completeLiveAssistantLesson() {
    liveAssistantCoordinator.clearPendingLesson()
    assistantRecipeContext = nil
    markTutorialQuest(.liveAgent)
  }

  private func openProfileEditor() {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }
    showProfile = true
  }

  private func openDashboardTab() {
    switch dashboardNavRoute {
    case .dashboard:
      selectedTab = .dashboard
    case .profile:
      showProfile = true
    case .onboarding:
      showOnboarding = true
    }
  }

  private func refreshOnboardingGate() async {
    do {
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
      if !hasOnboarded {
        selectedTab = .home
        showProfile = false
        if !firstRunExperienceStore.hasCompletedCurrentVersion {
          showOnboarding = true
        }
      }
    } catch {
      logger.error("Failed to check onboarding status: \(error.localizedDescription)")
    }
  }

  // MARK: - Tutorial Progress

  private func markTutorialQuest(_ quest: TutorialQuest) {
    var progress = TutorialProgress(storageString: tutorialStorageString)
    progress.markCompleted(quest)
    tutorialStorageString = progress.storageString
  }

  // MARK: - Full Reset

  private func performFullReset() {
    do {
      try deps.userDataRepository.resetAllUserData()
    } catch {
      logger.error("Failed to reset user data: \(error.localizedDescription)")
    }

    tutorialStorageString = ""
    spotlightCoordinator.activeSteps = nil
    assistantRecipeContext = nil
    tutorialCookingRecipe = nil
    liveAssistantCoordinator.matchedRecipe = nil
    liveAssistantCoordinator.matchedRecipeContext = nil
    liveAssistantCoordinator.clearPendingLesson()

    let tutorialKeys = ResetPolicy.tutorialKeysToClear(
      allKeys: TutorialStorageKeys.all,
      preserving: TutorialStorageKeys.progress
    )
    let keysToClear = ResetPolicy.defaultsKeysToClear(
      tutorialKeys: tutorialKeys,
      learningKeys: [
        LearningStorageKeys.suggestionsShown,
        LearningStorageKeys.suggestionsAccepted,
      ]
    )

    for key in keysToClear {
      UserDefaults.standard.removeObject(forKey: key)
    }

    hasOnboarded = false
    selectedTab = .home
    firstRunExperienceStore.reset()
    showOnboarding = true
  }

  // MARK: - Bottom Navigation

  private var bottomNav: some View {
    ZStack(alignment: .top) {
      HStack(spacing: 0) {
        navItem(
          icon: "house.fill",
          label: "Home",
          isActive: selectedTab == .home
        ) {
          selectedTab = .home
        }

        Spacer(minLength: AppTheme.Home.navCenterGap)

        navItem(
          icon: dashboardNavIcon,
          label: dashboardNavLabel,
          isActive: selectedTab == .dashboard
        ) {
          openDashboardTab()
        }
      }
      .padding(.horizontal, AppTheme.Space.lg)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.sm)
      .frame(maxWidth: .infinity)
      .background {
        RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          .fill(AppTheme.bg.opacity(0.92))
          .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.24), lineWidth: 1)
      }
      .shadow(color: AppTheme.Shadow.colorDeep.opacity(0.45), radius: 14, x: 0, y: 5)

      scanOrb
        .offset(y: -AppTheme.Home.navOrbLift)
        .accessibilityLabel("Scan options")
        .accessibilityHint("Tap for scan options, or press and hold to drag to an option")
    }
    .padding(.horizontal, AppTheme.Home.navHorizontalInset)
    .padding(.top, AppTheme.Space.xs + AppTheme.Home.navOrbLift)
    .padding(.bottom, 0)
  }

  private func navItem(
    icon: String,
    label: String,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: AppTheme.Space.xxxs) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .medium))
        Text(label)
          .font(AppTheme.Typography.labelSmall)
      }
      .foregroundStyle(isActive ? AppTheme.accent : AppTheme.textSecondary)
      .animation(.default, value: isActive)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(FLNavItemButtonStyle())
  }
}

// MARK: - Button Styles

private struct FLNavOrbButtonStyle: SwiftUI.ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}

private struct FLNavItemButtonStyle: SwiftUI.ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.80 : 1)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(reduceMotion ? nil : AppMotion.quick, value: configuration.isPressed)
  }
}
