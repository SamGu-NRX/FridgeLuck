import SwiftUI

struct HomeDashboardView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @StateObject private var viewModel: HomeDashboardViewModel
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  @State private var selectedTrendDate: Date?
  @State private var insightMode: HomeInsightMode = .macros
  @State private var heroAppeared = false
  @State private var showResetConfirmation = false
  @State private var showSkipConfirmation = false
  @AppStorage(TutorialStorageKeys.hasSeenSpotlightTutorial) private var hasSeenSpotlightTutorial =
    false
  @AppStorage(TutorialStorageKeys.hasSeenCompletionSpotlight)
  private var hasSeenCompletionSpotlight = false
  @AppStorage(TutorialStorageKeys.hasSeenFirstScanNudge) private var hasSeenFirstScanNudge = false

  let onScan: () -> Void
  let onDemoMode: () -> Void
  let onCompleteProfile: () -> Void
  let onExploreComplete: () -> Void
  let onReset: () -> Void
  var refreshTrigger: Int = 0
  let spotlightCoordinator: SpotlightCoordinator

  private enum SpotlightKind: String, Equatable {
    case onboarding
    case completion
    case firstScanNudge
  }

  init(
    deps: AppDependencies,
    onScan: @escaping () -> Void,
    onDemoMode: @escaping () -> Void,
    onCompleteProfile: @escaping () -> Void,
    onExploreComplete: @escaping () -> Void,
    onReset: @escaping () -> Void = {},
    refreshTrigger: Int = 0,
    spotlightCoordinator: SpotlightCoordinator
  ) {
    _viewModel = StateObject(wrappedValue: HomeDashboardViewModel(deps: deps))
    self.onScan = onScan
    self.onDemoMode = onDemoMode
    self.onCompleteProfile = onCompleteProfile
    self.onExploreComplete = onExploreComplete
    self.onReset = onReset
    self.refreshTrigger = refreshTrigger
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
          hasSeenFirstScanNudge = false
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
          "You\u{2019}ll skip the guided tour and go straight to the dashboard. You can still access demo mode and set up your profile later."
        )
      }
      .task {
        viewModel.syncTutorialProgress(tutorialProgress)
        guard viewModel.snapshot == nil else { return }
        await viewModel.load()
      }
      .refreshable {
        await viewModel.load()
      }
      .onChange(of: tutorialStorageString) {
        viewModel.syncTutorialProgress(tutorialProgress)
      }
      .onChange(of: refreshTrigger) {
        Task { await viewModel.load() }
      }
      .onAppear {
        if reduceMotion {
          heroAppeared = true
        } else {
          if !heroAppeared {
            withAnimation(AppMotion.heroAppear.delay(0.15)) {
              heroAppeared = true
            }
          }
        }
      }
      .task(id: pendingSpotlightKind) {
        guard let kind = pendingSpotlightKind else { return }
        let delay = reduceMotion ? 0.3 : 0.8
        let nanoseconds = UInt64(delay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else { return }
        guard pendingSpotlightKind == kind else { return }
        guard spotlightCoordinator.activeSteps == nil else { return }
        presentSpotlight(kind)
      }
      .onPreferenceChange(SpotlightAnchorKey.self) { spotlightCoordinator.anchors = $0 }
      .onAppear {
        spotlightCoordinator.onScrollToAnchor = { anchorID in
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(AppMotion.spotlightMove) {
              scrollProxy.scrollTo(anchorID, anchor: .center)
            }
          }
        }
      }
    }
    .flPageBackground()
  }

  private var pendingSpotlightKind: SpotlightKind? {
    guard spotlightCoordinator.activeSteps == nil else { return nil }
    guard viewModel.snapshot != nil else { return nil }

    if tutorialProgress.isComplete {
      guard !hasSeenCompletionSpotlight else { return nil }
      return anchorsReady(for: .completion) ? .completion : nil
    }

    if !hasSeenSpotlightTutorial {
      return anchorsReady(for: .onboarding) ? .onboarding : nil
    }

    if !hasSeenFirstScanNudge,
      tutorialProgress.isCompleted(.setupProfile),
      !tutorialProgress.isCompleted(.firstScan)
    {
      return anchorsReady(for: .firstScanNudge) ? .firstScanNudge : nil
    }

    return nil
  }

  private func steps(for kind: SpotlightKind) -> [SpotlightStep] {
    switch kind {
    case .onboarding:
      return SpotlightStep.onboarding
    case .completion:
      return SpotlightStep.completion
    case .firstScanNudge:
      return SpotlightStep.firstScanNudge
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
    spotlightCoordinator.activeSteps = steps(for: kind)
    switch kind {
    case .onboarding:
      hasSeenSpotlightTutorial = true
    case .completion:
      hasSeenCompletionSpotlight = true
    case .firstScanNudge:
      hasSeenFirstScanNudge = true
    }
  }

  // MARK: - Tutorial Home

  private func tutorialHome(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
      HomeTutorialWelcomeHeader(heroAppeared: heroAppeared)
        .padding(.horizontal, AppTheme.Space.page)

      TutorialProgressView(progress: tutorialProgress)
        .padding(.horizontal, AppTheme.Space.page)
        .id("progressView")
        .spotlightAnchor("progressView")
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 10)

      HomeTutorialQuestSection(
        tutorialProgress: tutorialProgress,
        tutorialStorageString: tutorialStorageString,
        heroAppeared: heroAppeared,
        reduceMotion: reduceMotion,
        onQuestAction: handleQuestAction
      )
      .padding(.horizontal, AppTheme.Space.page)

      if tutorialProgress.completedCount == 0 {
        HomeTutorialQuickStartHint()
          .padding(.horizontal, AppTheme.Space.page)
      }
    }
  }

  private func handleQuestAction(_ quest: TutorialQuest) {
    switch quest {
    case .setupProfile:
      onCompleteProfile()
    case .firstScan:
      onDemoMode()
    case .cookAndRate:
      onDemoMode()
    case .exploreMore:
      onExploreComplete()
    }
  }

  // MARK: - Mark Quest Completed (callable from outside)

  func markQuestCompleted(_ quest: TutorialQuest) {
    var progress = tutorialProgress
    progress.markCompleted(quest)
    tutorialStorageString = progress.storageString
    viewModel.completeQuest(quest)
  }

  // MARK: - Graduated Dashboard (existing analytics)

  private func graduatedDashboard(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HomeGraduatedEditorialHeader(
        timeGreeting: timeGreeting,
        editorialDate: editorialDate,
        onCompleteProfile: onCompleteProfile
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.lg)

      HomeGraduatedHeroSection(
        heroAppeared: heroAppeared,
        onDemoMode: onDemoMode
      )
      .padding(.bottom, AppTheme.Space.sectionBreak)

      HomeFloatingStatsSection(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

      HomeMyRhythmSection(snapshot: snapshot)
        .padding(.bottom, AppTheme.Space.sectionBreak)
        .spotlightAnchor("myRhythm")

      HomeFridgeLuckPanelsSection(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

      if snapshot.shouldUseStarterMode {
        HomeStarterPanelSection(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)
      } else {
        HomeInsightSection(
          insightMode: $insightMode,
          snapshot: snapshot
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)
      }

      HomeSecondaryActionsSection(
        snapshot: snapshot,
        onCompleteProfile: onCompleteProfile
      )
      .padding(.horizontal, AppTheme.Space.page)
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
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter.string(from: Date())
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
