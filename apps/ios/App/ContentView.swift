import FLFeatureLogic
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ContentView")

// MARK: - Navigation Coordinator

@MainActor
@Observable
final class NavigationCoordinator {
  var shouldReturnHome = false

  func returnHome() {
    shouldReturnHome = true
  }
}

// MARK: - App Tab

enum AppTab: Sendable {
  case home
  case kitchen
  case progress
  case settings
}

private struct OnboardingHomeHandoffOverlay: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var cardAppeared = false

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.96)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        ZStack {
          Circle()
            .fill(
              RadialGradient(
                colors: [AppTheme.accent.opacity(0.18), AppTheme.accent.opacity(0.03)],
                center: .center,
                startRadius: 16,
                endRadius: 72
              )
            )
            .frame(width: 132, height: 132)

          Image(systemName: "party.popper.fill")
            .font(.system(size: 42, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .accessibilityHidden(true)
        }

        VStack(spacing: AppTheme.Space.xs) {
          Text("Your kitchen is ready.")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Landing you in the guided demo so the first lesson feels continuous.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .scaleEffect(cardAppeared ? 1 : 0.97)
      .opacity(cardAppeared ? 1 : 0)
      .offset(y: cardAppeared ? 0 : 10)
    }
    .task {
      guard !cardAppeared else { return }
      if reduceMotion {
        cardAppeared = true
      } else {
        withAnimation(AppMotion.onboardingHandoffIn) {
          cardAppeared = true
        }
      }
    }
  }
}

struct ContentView: View {
  private struct HomeRecommendationRoute: Identifiable, Hashable, Sendable {
    let ingredientIds: Set<Int64>
    let ingredientNames: [String]
    let preferredRecipeID: Int64?

    var id: String {
      let recipePart = preferredRecipeID.map(String.init) ?? "none"
      let ingredientPart = ingredientIds.sorted().map(String.init).joined(separator: ",")
      return "\(recipePart)|\(ingredientPart)|\(ingredientNames.joined(separator: ","))"
    }
  }

  private enum Timing {
    static let navAppearanceDelay = 0.22
    static let scanModeSelectionDelay = Duration.milliseconds(150)
    static let onboardingHandoffFallbackReduced = Duration.milliseconds(450)
    static let onboardingHandoffFallbackStandard = Duration.milliseconds(1400)
    static let onboardingHandoffCleanupDelay = Duration.milliseconds(320)
  }

  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore

  @State private var selectedTab: AppTab = .home
  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToReverseScan = false
  @State private var navigateToDemoMode = false
  @State private var navigateToDirectReview = false
  @State private var navigateToDirectResults = false
  @State private var homeUpdateGroceriesLaunchMode: UpdateGroceriesLaunchMode?
  @State private var homeRecommendationRoute: HomeRecommendationRoute?
  @State private var kitchenUpdateGroceriesLaunchMode: UpdateGroceriesLaunchMode?
  @State private var assistantRecipeContext: LiveAssistantRecipeContext?
  @State private var showOnboarding = false
  @State private var navCoordinator = NavigationCoordinator()
  @State private var navAppeared = false
  @State private var spotlightCoordinator = SpotlightCoordinator()
  @State private var liveAssistantCoordinator = LiveAssistantCoordinator()
  @State private var settingsCoordinator = SettingsCoordinator()
  @State private var tutorialFlowContext = TutorialFlowContext()

  @State private var directReviewDetections: [Detection] = []
  @State private var directReviewImage: UIImage?
  @State private var directResultsIngredientIds: Set<Int64> = []
  @State private var directResultsIngredientNames: [String] = []
  @State private var directResultsImage: UIImage?
  @State private var onboardingHandoffToken: UUID?
  @State private var isOnboardingHandoffVisible = false
  @State private var questCompletionTask: Task<Void, Never>?
  @State private var onboardingHandoffFallbackTask: Task<Void, Never>?
  @State private var onboardingHandoffCleanupTask: Task<Void, Never>?
  @State private var scanModeSelectionTask: Task<Void, Never>?

  @State private var showScanModeMenu = false
  @State private var highlightedScanMode: ScanMode?

  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  @State private var orbTouchDownDate: Date?
  @State private var orbLongPressTriggered = false
  private let orbLongPressThreshold: TimeInterval = 0.35

  private var hasActiveHomeDestination: Bool {
    navigateToScan || navigateToReverseScan || navigateToDemoMode || navigateToDirectReview
      || navigateToDirectResults || homeUpdateGroceriesLaunchMode != nil
      || homeRecommendationRoute != nil || assistantRecipeContext != nil
  }

  private var hasActiveKitchenDestination: Bool {
    kitchenUpdateGroceriesLaunchMode != nil
  }

  private var shouldShowBottomNav: Bool {
    switch selectedTab {
    case .home:
      !hasActiveHomeDestination
    case .kitchen:
      !hasActiveKitchenDestination
    case .progress, .settings:
      true
    }
  }

  private var shouldShowSpotlightOverlay: Bool {
    selectedTab == .home && !hasActiveHomeDestination
  }

  var body: some View {
    ZStack {
      homeTab
      kitchenTab
      progressTab
      settingsTab

      onboardingHandoffOverlay
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
      if let presentation = spotlightCoordinator.activePresentation, shouldShowSpotlightOverlay {
        SpotlightTutorialOverlay(
          presentationID: presentation.id,
          steps: presentation.steps,
          anchors: spotlightCoordinator.anchors,
          isPresented: Binding(
            get: { spotlightCoordinator.activePresentation != nil },
            set: { isPresented in
              if !isPresented {
                spotlightCoordinator.dismissActivePresentation()
              }
            }
          ),
          onScrollToAnchor: spotlightCoordinator.onScrollToAnchor
        )
        .id(presentation.id)
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

      returnToHomeRoot()
      navCoordinator.shouldReturnHome = false
    }
    .onChange(of: tutorialFlowContext.questObjectiveCompleted) { _, completed in
      guard completed, let quest = tutorialFlowContext.activeQuest else { return }
      markTutorialQuest(quest)
      let flowContext = tutorialFlowContext

      questCompletionTask?.cancel()
      questCompletionTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 500))
        guard !Task.isCancelled else { return }

        navCoordinator.returnHome()
        flowContext.reset()
        questCompletionTask = nil
      }
    }
    .task {
      await refreshOnboardingGate()
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingView(isRequired: !hasOnboarded) {
        firstRunExperienceStore.markCompletedCurrentVersion()
        beginOnboardingHandoff()
        hasOnboarded = true
        selectedTab = .home
        showOnboarding = false
      }
      .interactiveDismissDisabled(!hasOnboarded)
      .environmentObject(deps)
    }
    .onAppear {
      if reduceMotion {
        navAppeared = true
      } else if !navAppeared {
        withAnimation(AppMotion.standard.delay(Timing.navAppearanceDelay)) {
          navAppeared = true
        }
      }
    }
  }

  @ViewBuilder
  private func tabHost<Content: View>(for tab: AppTab, @ViewBuilder content: () -> Content)
    -> some View
  {
    content()
      .opacity(selectedTab == tab ? 1 : 0)
      .scaleEffect(selectedTab == tab ? 1 : 0.985)
      .zIndex(selectedTab == tab ? 1 : 0)
      .allowsHitTesting(selectedTab == tab)
      .animation(reduceMotion ? nil : AppMotion.tabEntrance, value: selectedTab)
  }

  private var homeTab: some View {
    tabHost(for: .home) {
      NavigationStack {
        HomeDashboardView(
          deps: deps,
          onScan: openScan,
          onQuestCTA: handleQuestCTA,
          onDemoMode: openDemoMode,
          onCompleteProfile: openProfileEditor,
          onOpenRecommendation: openHomeRecommendation,
          onOpenAssistant: openLiveAssistant,
          onOpenVirtualFridge: openVirtualFridge,
          onSwitchToKitchen: openKitchenTab,
          onSwitchToProgress: openProgressTab,
          onReset: performFullReset,
          onOnboardingSpotlightWillPresent: releaseOnboardingHandoff,
          prefersAcceleratedOnboardingSpotlight: isOnboardingHandoffVisible,
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
        .navigationDestination(isPresented: $navigateToDirectReview) {
          IngredientReviewView(
            detections: directReviewDetections,
            scanProvenance: .bundledFixture,
            fridgeImage: directReviewImage
          )
        }
        .navigationDestination(isPresented: $navigateToDirectResults) {
          RecipeResultsView(
            ingredientIds: directResultsIngredientIds,
            ingredientNames: directResultsIngredientNames,
            fridgePhoto: directResultsImage,
            engine: deps.makeRecommendationEngine()
          )
        }
        .navigationDestination(item: $homeRecommendationRoute) { route in
          RecipeResultsView(
            ingredientIds: route.ingredientIds,
            ingredientNames: route.ingredientNames,
            preferredRecipeID: route.preferredRecipeID,
            engine: deps.makeRecommendationEngine()
          )
        }
        .navigationDestination(item: $homeUpdateGroceriesLaunchMode) { launchMode in
          UpdateGroceriesView(launchMode: launchMode)
        }
        .navigationDestination(item: $assistantRecipeContext) { recipeContext in
          LiveAssistantView(
            recipeContext: recipeContext,
            onCompleteLesson: completeLiveAssistantLesson,
            onSkipLesson: skipLiveAssistantLesson
          )
        }
      }
      .environment(navCoordinator)
      .environment(liveAssistantCoordinator)
      .environment(tutorialFlowContext)
    }
  }

  private var kitchenTab: some View {
    tabHost(for: .kitchen) {
      NavigationStack {
        KitchenView(
          deps: deps,
          onOpenGroceriesFlow: openKitchenGroceries
        )
        .navigationDestination(item: $kitchenUpdateGroceriesLaunchMode) { launchMode in
          UpdateGroceriesView(launchMode: launchMode)
        }
      }
    }
  }

  private var progressTab: some View {
    tabHost(for: .progress) {
      NavigationStack {
        ProgressTabView(deps: deps, onOpenProfileSettings: openProfileEditor)
      }
      .environmentObject(deps)
    }
  }

  private var settingsTab: some View {
    tabHost(for: .settings) {
      SettingsView(
        coordinator: settingsCoordinator,
        onProfileChanged: {
          Task { await refreshOnboardingGate() }
        },
        onResetAllData: performFullReset
      )
      .environmentObject(deps)
    }
  }

  @ViewBuilder
  private var onboardingHandoffOverlay: some View {
    if let onboardingHandoffToken, isOnboardingHandoffVisible {
      OnboardingHomeHandoffOverlay()
        .id(onboardingHandoffToken)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .zIndex(3)
        .allowsHitTesting(false)
    }
  }

  // MARK: - Scan Orb

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
            if orbTouchDownDate == nil {
              orbTouchDownDate = value.time
              orbLongPressTriggered = false
            }

            let elapsed = value.time.timeIntervalSince(orbTouchDownDate ?? value.time)

            if !orbLongPressTriggered && elapsed >= orbLongPressThreshold {
              orbLongPressTriggered = true
              AppPreferencesStore.haptic(.medium)
              showScanModeMenu = true
            }

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
              if let mode = highlightedScanMode {
                showScanModeMenu = false
                AppPreferencesStore.haptic(.light)
                scanModeSelectionTask?.cancel()
                scanModeSelectionTask = Task { @MainActor in
                  try? await Task.sleep(for: Timing.scanModeSelectionDelay)
                  guard !Task.isCancelled else { return }

                  handleScanModeSelection(mode)
                  scanModeSelectionTask = nil
                }
              }
            } else {
              if showScanModeMenu {
                showScanModeMenu = false
              } else {
                AppPreferencesStore.haptic(.light)
                showScanModeMenu = true
              }
            }

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
      openUpdateGroceries()
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

  private func openVirtualFridge() {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }
    openKitchenTab()
  }

  private func openUpdateGroceries(launchMode: UpdateGroceriesLaunchMode = .chooser) {
    switch AppFlowPolicy.scanEntryRoute(hasOnboarded: hasOnboarded) {
    case .scan:
      let targetTab: AppTab = selectedTab == .kitchen ? .kitchen : .home
      if targetTab == .home {
        clearHomeNavigation()
        selectedTab = .home
        homeUpdateGroceriesLaunchMode = launchMode
      } else {
        selectedTab = .kitchen
        kitchenUpdateGroceriesLaunchMode = launchMode
      }
    case .onboarding:
      showOnboarding = true
    }
  }

  private func openKitchenGroceries(_ launchMode: UpdateGroceriesLaunchMode) {
    openUpdateGroceries(launchMode: launchMode)
  }

  private func openKitchenTab() {
    switch AppFlowPolicy.kitchenEntryRoute(hasOnboarded: hasOnboarded) {
    case .kitchen:
      selectedTab = .kitchen
    case .emptyState:
      showOnboarding = true
    }
  }

  private func openProgressTab() {
    switch AppFlowPolicy.progressEntryRoute(
      hasOnboarded: hasOnboarded,
      isTutorialComplete: TutorialProgress(storageString: tutorialStorageString).isComplete
    ) {
    case .progress:
      selectedTab = .progress
    case .emptyState:
      if hasOnboarded {
        selectedTab = .home
      } else {
        showOnboarding = true
      }
    }
  }

  private func openHomeRecommendation(_ recommendation: HomeRecommendation) {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }

    clearHomeNavigation()
    selectedTab = .home
    homeRecommendationRoute = HomeRecommendationRoute(
      ingredientIds: recommendation.ingredientIDs,
      ingredientNames: [],
      preferredRecipeID: recommendation.recipeID
    )
  }

  private func handleQuestCTA(_ quest: TutorialQuest) {
    guard hasOnboarded else {
      showOnboarding = true
      return
    }

    tutorialFlowContext.beginQuest(quest)

    switch quest {
    case .firstScan:
      openDemoMode()
    case .ingredientReview:
      openDirectIngredientReview(scenario: .asianStirFry)
    case .pickRecipeMatch:
      openDirectRecipeResults(scenario: .mediterraneanLunch)
    case .cookWithLeChef:
      openLiveAssistant()
    }
  }

  private func openDirectIngredientReview(scenario: DemoScenario) {
    selectedTab = .home
    Task {
      let payload = await DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )
      directReviewDetections = payload.detections
      directReviewImage = payload.image
      navigateToDirectReview = true
    }
  }

  private func openDirectRecipeResults(scenario: DemoScenario) {
    selectedTab = .home
    Task {
      let payload = await DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )
      let ids = Set(payload.detections.map(\.ingredientId))
      let names = ids.map { IngredientLexicon.displayName(for: $0) }.sorted()

      directResultsIngredientIds = ids
      directResultsIngredientNames = names
      directResultsImage = payload.image
      navigateToDirectResults = true
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

  private func completeLiveAssistantLesson() {
    liveAssistantCoordinator.clearPendingLesson()
    assistantRecipeContext = nil

    if tutorialFlowContext.activeQuest == .cookWithLeChef {
      tutorialFlowContext.completeObjective()
    } else {
      markTutorialQuest(.cookWithLeChef)
    }
  }

  private func skipLiveAssistantLesson() {
    liveAssistantCoordinator.clearPendingLesson()
    assistantRecipeContext = nil
  }

  private func openProfileEditor() {
    selectedTab = .settings
    settingsCoordinator.open(.profileBasics)
  }

  private func clearHomeNavigation() {
    navigateToScan = false
    navigateToReverseScan = false
    navigateToDemoMode = false
    navigateToDirectReview = false
    navigateToDirectResults = false
    homeUpdateGroceriesLaunchMode = nil
    homeRecommendationRoute = nil
    assistantRecipeContext = nil
  }

  private func clearKitchenNavigation() {
    kitchenUpdateGroceriesLaunchMode = nil
  }

  private func returnToHomeRoot() {
    questCompletionTask?.cancel()
    questCompletionTask = nil
    scanModeSelectionTask?.cancel()
    scanModeSelectionTask = nil
    clearHomeNavigation()
    clearKitchenNavigation()
    selectedTab = .home
  }

  private func refreshOnboardingGate() async {
    do {
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
      if !hasOnboarded {
        selectedTab = .home
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
    spotlightCoordinator.activePresentation = nil
    tutorialFlowContext.reset()
    assistantRecipeContext = nil
    liveAssistantCoordinator.matchedRecipe = nil
    liveAssistantCoordinator.matchedRecipeContext = nil
    liveAssistantCoordinator.clearPendingLesson()
    settingsCoordinator.reset()
    onboardingHandoffFallbackTask?.cancel()
    onboardingHandoffFallbackTask = nil
    onboardingHandoffToken = nil
    isOnboardingHandoffVisible = false

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
    returnToHomeRoot()
    firstRunExperienceStore.reset()
    showOnboarding = true
  }

  private func beginOnboardingHandoff() {
    onboardingHandoffFallbackTask?.cancel()
    onboardingHandoffCleanupTask?.cancel()

    let token = UUID()
    onboardingHandoffToken = token

    if reduceMotion {
      isOnboardingHandoffVisible = true
    } else {
      withAnimation(AppMotion.onboardingHandoffIn) {
        isOnboardingHandoffVisible = true
      }
    }

    onboardingHandoffFallbackTask = Task { @MainActor in
      let fallbackDelay =
        reduceMotion
        ? Timing.onboardingHandoffFallbackReduced : Timing.onboardingHandoffFallbackStandard
      try? await Task.sleep(for: fallbackDelay)
      guard !Task.isCancelled else { return }
      guard onboardingHandoffToken == token else { return }
      releaseOnboardingHandoff()
    }
  }

  private func releaseOnboardingHandoff() {
    onboardingHandoffFallbackTask?.cancel()
    onboardingHandoffFallbackTask = nil
    onboardingHandoffCleanupTask?.cancel()
    onboardingHandoffCleanupTask = nil

    guard let token = onboardingHandoffToken else { return }

    if reduceMotion {
      isOnboardingHandoffVisible = false
      onboardingHandoffToken = nil
      return
    }

    withAnimation(AppMotion.onboardingHandoffOut) {
      isOnboardingHandoffVisible = false
    }

    onboardingHandoffCleanupTask = Task { @MainActor in
      try? await Task.sleep(for: Timing.onboardingHandoffCleanupDelay)
      guard !Task.isCancelled else { return }
      guard onboardingHandoffToken == token else { return }
      onboardingHandoffToken = nil
      onboardingHandoffCleanupTask = nil
    }
  }

  // MARK: - Bottom Navigation

  private var bottomNav: some View {
    ZStack(alignment: .top) {
      HStack(spacing: 0) {
        navItem(icon: "house.fill", label: "Home", isActive: selectedTab == .home) {
          selectedTab = .home
        }

        navItem(icon: "refrigerator.fill", label: "Kitchen", isActive: selectedTab == .kitchen) {
          selectedTab = .kitchen
        }

        Spacer(minLength: AppTheme.Home.navCenterGap)

        navItem(
          icon: "chart.line.uptrend.xyaxis", label: "Progress", isActive: selectedTab == .progress
        ) {
          selectedTab = .progress
        }

        navItem(icon: "gearshape", label: "Settings", isActive: selectedTab == .settings) {
          selectedTab = .settings
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
      .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isActive)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(FLNavItemButtonStyle())
  }
}

// MARK: - Button Styles

private struct FLNavItemButtonStyle: SwiftUI.ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.80 : 1)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(reduceMotion ? nil : AppMotion.quick, value: configuration.isPressed)
  }
}
