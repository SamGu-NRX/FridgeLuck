import SwiftUI

struct HomeDashboardView: View {
  private enum SpotlightDelay {
    static let acceleratedReducedMotion = Duration.milliseconds(80)
    static let reducedMotion = Duration.milliseconds(220)
    static let accelerated = Duration.milliseconds(180)
    static let onboarding = Duration.milliseconds(500)
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
  @State private var spotlightScrollTask: Task<Void, Never>?
  @AppStorage(TutorialStorageKeys.hasSeenSpotlightTutorial) private var hasSeenSpotlightTutorial =
    false
  @AppStorage(TutorialStorageKeys.hasSeenLiveAssistantLesson)
  private var hasSeenLiveAssistantLesson = false

  let onScan: () -> Void
  let onCompleteProfile: () -> Void
  let onOpenRecommendation: (HomeRecommendation) -> Void
  let onOpenAssistant: () -> Void
  let onOpenVirtualFridge: () -> Void
  let onSwitchToKitchen: () -> Void
  let onSwitchToProgress: () -> Void
  let onOnboardingSpotlightWillPresent: () -> Void
  let prefersAcceleratedOnboardingSpotlight: Bool
  let spotlightCoordinator: SpotlightCoordinator

  /// `onboarding` is the short tour of this dashboard shown once after setup. Skipping it or
  /// finishing it both only mark it seen; there is no "tour complete" state to celebrate.
  private enum SpotlightKind: String, Equatable {
    case onboarding
    case liveAssistantLesson
  }

  init(
    deps: AppDependencies,
    onScan: @escaping () -> Void,
    onCompleteProfile: @escaping () -> Void,
    onOpenRecommendation: @escaping (HomeRecommendation) -> Void = { _ in },
    onOpenAssistant: @escaping () -> Void,
    onOpenVirtualFridge: @escaping () -> Void = {},
    onSwitchToKitchen: @escaping () -> Void = {},
    onSwitchToProgress: @escaping () -> Void = {},
    onOnboardingSpotlightWillPresent: @escaping () -> Void = {},
    prefersAcceleratedOnboardingSpotlight: Bool = false,
    spotlightCoordinator: SpotlightCoordinator
  ) {
    _viewModel = StateObject(wrappedValue: HomeDashboardViewModel(deps: deps))
    self.onScan = onScan
    self.onCompleteProfile = onCompleteProfile
    self.onOpenRecommendation = onOpenRecommendation
    self.onOpenAssistant = onOpenAssistant
    self.onOpenVirtualFridge = onOpenVirtualFridge
    self.onSwitchToKitchen = onSwitchToKitchen
    self.onSwitchToProgress = onSwitchToProgress
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
            dashboard(snapshot: snapshot)
          } else if viewModel.isLoading {
            loadingState
              .padding(.horizontal, AppTheme.Space.page)
          } else {
            errorState
              .padding(.horizontal, AppTheme.Space.page)
          }
        }
        .padding(.top, AppTheme.Space.md)
        .padding(
          .bottom,
          AppTheme.Space.bottomClearance + AppTheme.Home.navOrbLift + AppTheme.Home.navBaseOffset
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
      .onDisappear {
        spotlightScrollTask?.cancel()
        spotlightScrollTask = nil
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

    if !hasSeenSpotlightTutorial {
      return heroAppeared && anchorsReady(for: .onboarding) ? .onboarding : nil
    }

    if liveAssistantCoordinator.shouldPresentLesson,
      !tutorialProgress.isCompleted(.cookWithLeChef),
      !hasSeenLiveAssistantLesson
    {
      return anchorsReady(for: .liveAssistantLesson) ? .liveAssistantLesson : nil
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
    case .liveAssistantLesson:
      return SpotlightDelay.lesson
    }
  }

  private func steps(for kind: SpotlightKind) -> [SpotlightStep] {
    switch kind {
    case .onboarding:
      return SpotlightStep.homeTour(
        hasRecommendation: viewModel.snapshot?.primaryRecommendation != nil
      )
    case .liveAssistantLesson:
      return SpotlightStep.liveAssistantLesson
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
    case .liveAssistantLesson:
      hasSeenLiveAssistantLesson = true
    }
  }

  // MARK: - Dashboard

  /// Home shows the user's own kitchen whether or not they took the tour. Tour progress must
  /// not gate this view: a gate here hid a real kitchen behind a four-step demo checklist
  /// ("Quick Setup 0/4") that real scans and cooks never advanced.
  private func dashboard(snapshot: HomeDashboardSnapshot) -> some View {
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
          guard let recommendation = snapshot.primaryRecommendation else { return }
          onOpenRecommendation(recommendation)
        },
        onScan: onScan,
        hasRecommendation: snapshot.primaryRecommendation != nil
      )
      .id(SpotlightStep.homeRecommendationAnchorID)
      .spotlightAnchor(SpotlightStep.homeRecommendationAnchorID)
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
          options: snapshot.fallbackOptions.map { rec in
            HomeFallbackOption(
              id: rec.id,
              recipeName: rec.recipeName,
              cookTimeMinutes: rec.cookTimeMinutes,
              badgeLabel: rec.badgeLabel ?? "Option",
              badgeColor: AppTheme.sage
            )
          },
          onSelect: { option in
            guard let recommendation = snapshot.fallbackOptions.first(where: { $0.id == option.id })
            else {
              return
            }
            onOpenRecommendation(recommendation)
          }
        )
        .padding(.bottom, AppTheme.Space.sectionBreak)
      }

      HomeMyRhythmSection(snapshot: snapshot)
        .padding(.bottom, AppTheme.Space.sectionBreak)
        .id("myRhythm")
        .spotlightAnchor("myRhythm")

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
    // Tour targets scroll to the top, not the center: Home's cards are tall, and a centered
    // card left no room above or below for the tour card, which then covered it.
    spotlightCoordinator.onScrollToAnchor = { anchorID in
      spotlightScrollTask?.cancel()

      guard !reduceMotion else {
        scrollProxy.scrollTo(anchorID, anchor: .top)
        return
      }

      spotlightScrollTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }

        withAnimation(AppMotion.spotlightMove) {
          scrollProxy.scrollTo(anchorID, anchor: .top)
        }
        spotlightScrollTask = nil
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
