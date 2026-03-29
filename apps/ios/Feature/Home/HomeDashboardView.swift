import SwiftUI

struct HomeDashboardView: View {
  private enum SpotlightDelay {
    static let acceleratedReducedMotion = Duration.milliseconds(80)
    static let reducedMotion = Duration.milliseconds(220)
    static let accelerated = Duration.milliseconds(180)
    static let onboarding = Duration.milliseconds(500)
    static let completion = Duration.milliseconds(450)
    static let lesson = Duration.milliseconds(650)
  }

  private static let editorialDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
  }()

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(LiveAssistantCoordinator.self) private var liveAssistantCoordinator

  @StateObject private var viewModel: HomeDashboardViewModel
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  @State private var heroAppeared = false
  @State private var showResetConfirmation = false
  @State private var showSkipConfirmation = false
  @AppStorage(TutorialStorageKeys.hasSeenSpotlightTutorial) private var hasSeenSpotlightTutorial =
    false
  @AppStorage(TutorialStorageKeys.hasSeenCompletionSpotlight)
  private var hasSeenCompletionSpotlight = false
  @AppStorage(TutorialStorageKeys.hasSeenLiveAssistantLesson)
  private var hasSeenLiveAssistantLesson = false
  @AppStorage(TutorialStorageKeys.lastAdvanceSpotlightQuestShown)
  private var lastAdvanceSpotlightQuestShown = -1

  let onScan: () -> Void
  let onQuestCTA: (TutorialQuest) -> Void
  let onDemoMode: () -> Void
  let onCompleteProfile: () -> Void
  let onOpenAssistant: () -> Void
  let onOpenVirtualFridge: () -> Void
  let onSwitchToKitchen: () -> Void
  let onSwitchToProgress: () -> Void
  let onReset: () -> Void
  let onOnboardingSpotlightWillPresent: () -> Void
  let prefersAcceleratedOnboardingSpotlight: Bool
  let spotlightCoordinator: SpotlightCoordinator

  private enum SpotlightKind: String, Equatable {
    case onboarding
    case completion
    case liveAssistantLesson
    case questAdvance
  }

  init(
    deps: AppDependencies,
    onScan: @escaping () -> Void,
    onQuestCTA: @escaping (TutorialQuest) -> Void,
    onDemoMode: @escaping () -> Void,
    onCompleteProfile: @escaping () -> Void,
    onOpenAssistant: @escaping () -> Void,
    onOpenVirtualFridge: @escaping () -> Void = {},
    onSwitchToKitchen: @escaping () -> Void = {},
    onSwitchToProgress: @escaping () -> Void = {},
    onReset: @escaping () -> Void = {},
    onOnboardingSpotlightWillPresent: @escaping () -> Void = {},
    prefersAcceleratedOnboardingSpotlight: Bool = false,
    spotlightCoordinator: SpotlightCoordinator
  ) {
    _viewModel = StateObject(wrappedValue: HomeDashboardViewModel(deps: deps))
    self.onScan = onScan
    self.onQuestCTA = onQuestCTA
    self.onDemoMode = onDemoMode
    self.onCompleteProfile = onCompleteProfile
    self.onOpenAssistant = onOpenAssistant
    self.onOpenVirtualFridge = onOpenVirtualFridge
    self.onSwitchToKitchen = onSwitchToKitchen
    self.onSwitchToProgress = onSwitchToProgress
    self.onReset = onReset
    self.onOnboardingSpotlightWillPresent = onOnboardingSpotlightWillPresent
    self.prefersAcceleratedOnboardingSpotlight = prefersAcceleratedOnboardingSpotlight
    self.spotlightCoordinator = spotlightCoordinator
  }

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
  }

  // MARK: - Body

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let snapshot = viewModel.snapshot {
            if tutorialProgress.isComplete {
              graduatedDashboard(snapshot: snapshot)
            } else {
              tutorialHome(snapshot: snapshot)
            }
          } else if viewModel.isLoading {
            loadingState
              .padding(.horizontal, AppTheme.Space.page)
          } else {
            errorState
              .padding(.horizontal, AppTheme.Space.page)
          }

          HomeResetFooterSection(
            tutorialProgress: tutorialProgress,
            onResetTap: { showResetConfirmation = true },
            onSkipTourTap: { showSkipConfirmation = true }
          )
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.sectionBreak)
        }
        .padding(.top, AppTheme.Space.md)
        .padding(
          .bottom,
          AppTheme.Space.bottomClearance + AppTheme.Home.navOrbLift + AppTheme.Home.navBaseOffset
        )
      }
      .alert("Start fresh?", isPresented: $showResetConfirmation) {
        Button("Reset Everything", role: .destructive) {
          tutorialStorageString = ""
          hasSeenSpotlightTutorial = false
          hasSeenCompletionSpotlight = false
          hasSeenLiveAssistantLesson = false
          lastAdvanceSpotlightQuestShown = -1
          onReset()
          Task { await viewModel.load() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This will erase your profile, cooking history, badges, and streaks. Recipes and ingredients stay. You\u{2019}ll see the guided tour again."
        )
      }
      .alert("Skip guided tour?", isPresented: $showSkipConfirmation) {
        Button("Skip Tour", role: .destructive) {
          let allQuests = Set(TutorialQuest.allCases.map(\.rawValue))
          let completed = TutorialProgress(completedQuestRawValues: allQuests)
          withAnimation(reduceMotion ? nil : AppMotion.standard) {
            tutorialStorageString = completed.storageString
          }
        }
        Button("Continue Tour", role: .cancel) {}
      } message: {
        Text(
          "You\u{2019}ll skip the guided tour and unlock the dashboard now. You can still explore demo mode anytime."
        )
      }
      .task {
        guard viewModel.snapshot == nil else { return }
        await viewModel.load()
      }
      .refreshable {
        await viewModel.load()
      }
      .onAppear {
        handleHeroAppearance()
        configureSpotlightCallbacks(using: scrollProxy)
      }
      .task(id: pendingSpotlightKind) {
        guard let kind = pendingSpotlightKind else { return }
        try? await Task.sleep(for: spotlightPresentationDelay(for: kind))
        guard !Task.isCancelled else { return }
        guard pendingSpotlightKind == kind else { return }
        guard spotlightCoordinator.activePresentation == nil else { return }
        presentSpotlight(kind)
      }
      .onPreferenceChange(SpotlightAnchorKey.self) {
        spotlightCoordinator.updateAnchors($0)
      }
    }
    .flPageBackground()
  }

  private var pendingSpotlightKind: SpotlightKind? {
    guard spotlightCoordinator.activePresentation == nil else { return nil }
    guard viewModel.snapshot != nil else { return nil }

    if tutorialProgress.isComplete {
      guard !hasSeenCompletionSpotlight else { return nil }
      return anchorsReady(for: .completion) ? .completion : nil
    }

    if !hasSeenSpotlightTutorial {
      return heroAppeared && anchorsReady(for: .onboarding) ? .onboarding : nil
    }

    if liveAssistantCoordinator.shouldPresentLesson,
      !tutorialProgress.isCompleted(.cookWithLeChef),
      !hasSeenLiveAssistantLesson
    {
      return anchorsReady(for: .liveAssistantLesson) ? .liveAssistantLesson : nil
    }

    if let nextQuest = tutorialProgress.currentQuest,
      tutorialProgress.completedCount > 0,
      lastAdvanceSpotlightQuestShown < nextQuest.rawValue
    {
      return heroAppeared && anchorsReady(for: .questAdvance) ? .questAdvance : nil
    }

    return nil
  }

  private func spotlightPresentationDelay(for kind: SpotlightKind) -> Duration {
    if reduceMotion {
      return kind == .onboarding && prefersAcceleratedOnboardingSpotlight
        ? SpotlightDelay.acceleratedReducedMotion
        : SpotlightDelay.reducedMotion
    }

    if kind == .onboarding && prefersAcceleratedOnboardingSpotlight {
      return SpotlightDelay.accelerated
    }

    switch kind {
    case .onboarding:
      return SpotlightDelay.onboarding
    case .completion:
      return SpotlightDelay.completion
    case .liveAssistantLesson, .questAdvance:
      return SpotlightDelay.lesson
    }
  }

  private func steps(for kind: SpotlightKind) -> [SpotlightStep] {
    switch kind {
    case .onboarding:
      return SpotlightStep.onboarding
    case .completion:
      return SpotlightStep.completion
    case .liveAssistantLesson:
      return SpotlightStep.liveAssistantLesson
    case .questAdvance:
      guard let quest = tutorialProgress.currentQuest else { return [] }
      return SpotlightStep.questAdvance(for: quest)
    }
  }

  private func anchorsReady(for kind: SpotlightKind) -> Bool {
    let requiredAnchorIDs = Set(steps(for: kind).compactMap(\.anchorID))
    guard !requiredAnchorIDs.isEmpty else { return true }

    for anchorID in requiredAnchorIDs {
      guard let rect = spotlightCoordinator.anchors[anchorID] else { return false }
      if rect.isEmpty || rect.isNull || rect.isInfinite {
        return false
      }
    }
    return true
  }

  private func presentSpotlight(_ kind: SpotlightKind) {
    let spotlightSteps = steps(for: kind)
    guard !spotlightSteps.isEmpty else { return }
    guard anchorsReady(for: kind) else { return }

    if kind == .onboarding {
      onOnboardingSpotlightWillPresent()
    }

    spotlightCoordinator.present(steps: spotlightSteps, source: kind.rawValue)
  }

  private func handleSpotlightDismissal(for source: String) {
    guard let kind = SpotlightKind(rawValue: source) else { return }

    switch kind {
    case .onboarding:
      hasSeenSpotlightTutorial = true
    case .completion:
      hasSeenCompletionSpotlight = true
    case .liveAssistantLesson:
      hasSeenLiveAssistantLesson = true
    case .questAdvance:
      if let quest = tutorialProgress.currentQuest {
        lastAdvanceSpotlightQuestShown = quest.rawValue
      }
    }
  }

  // MARK: - Tutorial Home

  private func tutorialHome(snapshot: HomeDashboardSnapshot) -> some View {
    let shouldFeatureLiveCook =
      tutorialProgress.currentQuest == .cookWithLeChef
      && liveAssistantCoordinator.matchedRecipeContext != nil

    return VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
      HomeTutorialWelcomeHeader(heroAppeared: heroAppeared)
        .padding(.horizontal, AppTheme.Space.page)

      TutorialProgressView(progress: tutorialProgress)
        .padding(.horizontal, AppTheme.Space.page)
        .id("progressView")
        .spotlightAnchor("progressView")
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 10)

      if shouldFeatureLiveCook, let recipeContext = liveAssistantCoordinator.matchedRecipeContext {
        HomeLiveAssistantSection(
          recipeContext: recipeContext,
          isTutorialActive: true,
          onOpenAssistant: onOpenAssistant
        )
        .padding(.horizontal, AppTheme.Space.page)
        .id("liveAssistantEntry")
        .spotlightAnchor("liveAssistantEntry")
      } else {
        HomeTutorialQuestSection(
          tutorialProgress: tutorialProgress,
          tutorialStorageString: tutorialStorageString,
          heroAppeared: heroAppeared,
          reduceMotion: reduceMotion,
          onQuestAction: handleQuestAction
        )
        .padding(.horizontal, AppTheme.Space.page)
      }

      if tutorialProgress.completedCount == 0 {
        HomeTutorialQuickStartHint()
          .padding(.horizontal, AppTheme.Space.page)
      }
    }
  }

  private func handleQuestAction(_ quest: TutorialQuest) {
    onQuestCTA(quest)
  }

  private func graduatedDashboard(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HomeDecisionHeader(
        timeGreeting: timeGreeting,
        editorialDate: editorialDate,
        currentStreak: snapshot.currentStreak,
        weekActivity: weekActivityFromSnapshot(snapshot)
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.sectionBreak)
      .opacity(heroAppeared ? 1 : 0)
      .offset(y: heroAppeared ? 0 : 10)

      HomeDailyNutritionRing(
        caloriesConsumed: snapshot.todayCalories,
        calorieGoal: snapshot.calorieGoal,
        proteinCurrent: snapshot.todayProtein,
        proteinGoal: snapshot.proteinGoal,
        carbsCurrent: snapshot.todayCarbs,
        carbsGoal: snapshot.carbsGoal,
        fatCurrent: snapshot.todayFat,
        fatGoal: snapshot.fatGoal,
        onTap: onSwitchToProgress
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.lg)
      .opacity(heroAppeared ? 1 : 0)
      .offset(y: heroAppeared ? 0 : 10)

      if let recipeContext = liveAssistantCoordinator.matchedRecipeContext {
        HomeLiveAssistantSection(
          recipeContext: recipeContext,
          isTutorialActive: false,
          onOpenAssistant: onOpenAssistant
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)
        .id("liveAssistantEntry")
        .spotlightAnchor("liveAssistantEntry")
      }

      HomePrimaryRecommendationCard(
        recipeName: snapshot.primaryRecommendation?.recipeName ?? "",
        explanation: snapshot.primaryRecommendation?.explanation ?? "",
        cookTimeMinutes: snapshot.primaryRecommendation?.cookTimeMinutes,
        matchLabel: snapshot.primaryRecommendation?.matchLabel,
        onCook: {
          // TODO: Route the primary recommendation into the cooking flow once Home can launch recipes directly.
        },
        onScan: onScan,
        hasRecommendation: snapshot.primaryRecommendation != nil
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.sectionBreak)

      if let urgent = snapshot.useSoonSuggestions.first {
        HomeUseSoonAlert(
          ingredientName: urgent.ingredientName,
          daysRemaining: urgent.daysRemaining,
          onTap: onSwitchToKitchen
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.lg)
      }

      if !snapshot.fallbackOptions.isEmpty {
        HomeFallbackOptionsRow(
          options: snapshot.fallbackOptions.enumerated().map { index, rec in
            HomeFallbackOption(
              id: "\(index)-\(rec.recipeName)-\(rec.cookTimeMinutes ?? -1)",
              recipeName: rec.recipeName,
              cookTimeMinutes: rec.cookTimeMinutes,
              badgeLabel: rec.badgeLabel ?? "Option",
              badgeColor: AppTheme.sage
            )
          },
          onSelect: { _ in
            // TODO: Route fallback recommendations into the cooking flow once Home can launch recipes directly.
          }
        )
        .padding(.bottom, AppTheme.Space.sectionBreak)
      }

      if snapshot.ingredientCount == 0 {
        HomeGraduatedHeroSection(
          heroAppeared: heroAppeared,
          onDemoMode: onDemoMode
        )
        .padding(.bottom, AppTheme.Space.sectionBreak)
      }

      HomeSecondaryActionsSection(
        snapshot: snapshot,
        onCompleteProfile: onCompleteProfile
      )
      .padding(.horizontal, AppTheme.Space.page)
    }
  }

  private func weekActivityFromSnapshot(_ snapshot: HomeDashboardSnapshot) -> [Bool] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let weekday = calendar.component(.weekday, from: today)
    let daysFromMonday = (weekday + 5) % 7
    guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else {
      return Array(repeating: false, count: 7)
    }

    let mealDates = Set(snapshot.mealsLast14Days.map { calendar.startOfDay(for: $0.date) })
    return (0..<7).map { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return false }
      return mealDates.contains(day)
    }
  }

  private var timeGreeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12: return "Good morning."
    case 12..<17: return "Good afternoon."
    default: return "Good evening."
    }
  }

  private var editorialDate: String {
    Self.editorialDateFormatter.string(from: Date())
  }

  private func handleHeroAppearance() {
    if reduceMotion {
      heroAppeared = true
      return
    }

    guard !heroAppeared else { return }
    withAnimation(AppMotion.heroAppear.delay(0.15)) {
      heroAppeared = true
    }
  }

  private func configureSpotlightCallbacks(using scrollProxy: ScrollViewProxy) {
    spotlightCoordinator.onScrollToAnchor = { anchorID in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        withAnimation(AppMotion.spotlightMove) {
          scrollProxy.scrollTo(anchorID, anchor: .center)
        }
      }
    }
    spotlightCoordinator.onDismissPresentation = { presentation in
      handleSpotlightDismissal(for: presentation.source)
    }
  }

  // MARK: - Loading / Error

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)
      Text("Preparing your kitchen...")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xxl)
  }

  private var errorState: some View {
    FLEmptyState(
      title: "Dashboard unavailable",
      message: viewModel.errorMessage ?? "Please try again.",
      systemImage: "exclamationmark.triangle.fill",
      actionTitle: "Retry",
      action: { Task { await viewModel.load() } }
    )
  }
}
