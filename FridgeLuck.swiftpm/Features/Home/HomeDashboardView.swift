import Charts
import SwiftUI

struct HomeDashboardView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @StateObject private var viewModel: HomeDashboardViewModel
  @AppStorage("tutorialProgressStorage") private var tutorialStorageString = ""

  @State private var selectedTrendDate: Date?
  @State private var insightMode: InsightMode = .macros
  @State private var heroAppeared = false
  @State private var showResetConfirmation = false
  @State private var showSkipConfirmation = false
  @AppStorage("hasSeenSpotlightTutorial") private var hasSeenSpotlightTutorial = false
  @AppStorage("hasSeenCompletionSpotlight") private var hasSeenCompletionSpotlight = false
  @AppStorage("hasSeenFirstScanNudge") private var hasSeenFirstScanNudge = false

  let onScan: () -> Void
  let onDemoMode: () -> Void
  let onCompleteProfile: () -> Void
  let onExploreComplete: () -> Void
  let onReset: () -> Void
  var refreshTrigger: Int = 0
  let spotlightCoordinator: SpotlightCoordinator

  private enum InsightMode: String, CaseIterable, Identifiable {
    case macros = "Macros"
    case cadence = "Cadence"
    var id: String { rawValue }
  }

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

          resetFooter
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sectionBreak)
        }
        .padding(.top, AppTheme.Space.md)
        // Keep footer actions reachable above the persistent bottom navigation + raised scan orb.
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
      welcomeHeader
        .padding(.horizontal, AppTheme.Space.page)

      TutorialProgressView(progress: tutorialProgress)
        .padding(.horizontal, AppTheme.Space.page)
        .id("progressView")
        .spotlightAnchor("progressView")
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 10)

      questSection
        .padding(.horizontal, AppTheme.Space.page)

      if tutorialProgress.completedCount == 0 {
        quickStartHint
          .padding(.horizontal, AppTheme.Space.page)
      }
    }
  }

  // MARK: - Welcome Header

  private var welcomeHeader: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text("Welcome to")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
        .textCase(.uppercase)
        .kerning(1.2)

      Text("FridgeLuck")
        .font(AppTheme.Typography.displayLarge)
        .foregroundStyle(AppTheme.textPrimary)

      Text(
        "Welcome to your guided tour. A few quick steps to set up your profile and explore the app."
      )
      .font(AppTheme.Typography.bodyLarge)
      .foregroundStyle(AppTheme.textSecondary)
      .padding(.top, AppTheme.Space.xxs)
    }
    .opacity(heroAppeared ? 1 : 0)
    .offset(y: heroAppeared ? 0 : 16)
  }

  // MARK: - Quest Section

  private var questSection: some View {
    VStack(spacing: AppTheme.Space.sm) {
      ForEach(TutorialQuest.allCases) { quest in
        let state = cardState(for: quest)

        TutorialQuestCard(quest: quest, state: state) {
          handleQuestAction(quest)
        }
        .id("quest_\(quest.rawValue)")
        .spotlightAnchor("quest_\(quest.rawValue)")
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 12)
        .animation(
          reduceMotion
            ? nil
            : AppMotion.cardSpring.delay(Double(quest.staggerIndex) * AppMotion.staggerDelay + 0.1),
          value: heroAppeared
        )
        .animation(reduceMotion ? nil : AppMotion.standard, value: tutorialStorageString)
      }
    }
  }

  private func cardState(for quest: TutorialQuest) -> TutorialQuestCard.QuestCardState {
    if tutorialProgress.isCompleted(quest) {
      return .completed
    } else if tutorialProgress.currentQuest == quest {
      return .active
    } else {
      return .locked
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

  // MARK: - Quick Start Hint

  private var quickStartHint: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(AppTheme.oat)

      Text(
        "Start with \u{201C}Set Up Your Kitchen\u{201D} \u{2014} it takes about 30 seconds to begin."
      )
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.oat.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.18), lineWidth: 1)
    )
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
      editorialHeader(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.lg)

      heroComposition
        .padding(.bottom, AppTheme.Space.sectionBreak)

      floatingStats(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

      myRhythmSection(snapshot: snapshot)
        .padding(.bottom, AppTheme.Space.sectionBreak)
        .spotlightAnchor("myRhythm")

      fridgeLuckPanels(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

      if snapshot.shouldUseStarterMode {
        starterPanel(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)
      } else {
        insightSection(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)
      }

      secondaryActions(snapshot: snapshot)
        .padding(.horizontal, AppTheme.Space.page)
    }
  }

  // MARK: - Editorial Header

  private func editorialHeader(snapshot: HomeDashboardSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(timeGreeting)
          .font(AppTheme.Typography.displayLarge)
          .foregroundStyle(AppTheme.textPrimary)

        Text(editorialDate)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(.uppercase)
          .kerning(1.2)
      }

      Spacer()

      Button(action: onCompleteProfile) {
        Text("FridgeLuck")
          .font(.system(.caption2, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.oat)
          .kerning(0.8)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open onboarding")
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

  // MARK: - Hero Composition

  private var heroComposition: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Image(systemName: "sparkles")
          .font(.system(size: 32, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 64, height: 64)
          .background(Circle().fill(.white.opacity(0.15)))

        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("Demo Mode")
            .font(AppTheme.Typography.displayLarge)
            .foregroundStyle(.white)

          Text("Pick a pre-stocked fridge and explore recipes.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(.white.opacity(0.78))
        }
      }

      FLPrimaryButton("Try Demo Mode", systemImage: "play.fill") {
        onDemoMode()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(AppTheme.Space.page)
    .padding(.vertical, AppTheme.Space.lg)
    .background(
      LinearGradient(
        colors: [AppTheme.accent, AppTheme.accent.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .overlay(alignment: .topTrailing) {
      Circle()
        .fill(.white.opacity(0.06))
        .frame(width: 200, height: 200)
        .blur(radius: 40)
        .offset(x: 60, y: -50)
        .allowsHitTesting(false)
    }
    .clipShape(FLDiagonalClip(cutHeight: 32))
    .shadow(color: AppTheme.accent.opacity(0.20), radius: 24, x: 0, y: 12)
    .opacity(heroAppeared ? 1 : 0)
    .offset(y: heroAppeared ? 0 : 16)
  }

  // MARK: - Floating Stats (NOT in a card)

  private func floatingStats(snapshot: HomeDashboardSnapshot) -> some View {
    HStack(spacing: 0) {
      statItem(value: "\(snapshot.currentStreak)", label: "day streak")
      thinDivider
      statItem(value: "\(snapshot.mealsLast7Days)", label: "this week")
      thinDivider
      statItem(value: "\(snapshot.recipeCount)", label: "recipes")
    }
  }

  private func statItem(value: String, label: String) -> some View {
    VStack(spacing: AppTheme.Space.xxxs) {
      Text(value)
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .contentTransition(.numericText())
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var thinDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.30))
      .frame(width: 1, height: AppTheme.Home.statDividerHeight)
  }

  // MARK: - My Rhythm Section (replaces Your Rhythm)

  private func myRhythmSection(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("My Rhythm")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Your cooking at a glance")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        Image(systemName: "book.closed.fill")
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 16, weight: .medium))
      }
      .padding(.horizontal, AppTheme.Space.page)

      if let latestEntry = snapshot.latestJournalEntry {
        latestRecipeCard(entry: latestEntry)
          .padding(.horizontal, AppTheme.Space.page)
      } else {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: "fork.knife")
            .font(.system(size: 18))
            .foregroundStyle(AppTheme.oat)
            .frame(width: 44, height: 44)
            .background(AppTheme.surfaceMuted, in: Circle())

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("No meals cooked yet")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Try demo mode to cook your first recipe!")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
          Spacer()
        }
        .padding(AppTheme.Space.md)
        .background(
          AppTheme.surface,
          in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
            .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, AppTheme.Space.page)
      }

      FLWaveDivider()
        .padding(.horizontal, AppTheme.Space.page)
    }
  }

  private func latestRecipeCard(entry: CookingJournalEntry) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.sm) {
        ZStack {
          AppTheme.surfaceMuted
          Image(systemName: "fork.knife")
            .font(.system(size: 18))
            .foregroundStyle(AppTheme.oat)
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(entry.recipe.title)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .fontWeight(.medium)
            .lineLimit(2)

          Text(entry.cookedAt, format: .dateTime.month(.abbreviated).day())
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)

          if let rating = entry.rating, rating > 0 {
            HStack(spacing: 2) {
              ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                  .font(.system(size: 10))
                  .foregroundStyle(
                    star <= rating ? AppTheme.accent : AppTheme.oat.opacity(0.3)
                  )
              }
            }
          }
        }

        Spacer()

        VStack(spacing: AppTheme.Space.xxxs) {
          Text("\(Int(entry.macrosConsumed.calories.rounded()))")
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("cal")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
  }

  // MARK: - Fridge / Luck Panels (overlapping, collage-style)

  private func fridgeLuckPanels(snapshot: HomeDashboardSnapshot) -> some View {
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Text("Your Fridge")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("\(snapshot.ingredientCount)")
          .font(AppTheme.Typography.displayLarge)
          .foregroundStyle(AppTheme.sage)
        Text("ingredients scanned")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.lg)
      .background(
        AppTheme.sageLight.opacity(0.18),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
          .stroke(AppTheme.sage.opacity(0.20), lineWidth: 1)
      )
      .rotationEffect(.degrees(-1.2), anchor: .bottomLeading)
      .frame(width: UIScreen.main.bounds.width * 0.58)

      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Text("Your Luck")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(.white)

        Text("\(snapshot.recipeCount)")
          .font(AppTheme.Typography.displayLarge)
          .foregroundStyle(AppTheme.accentLight)
        Text("recipes possible")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(.white.opacity(0.7))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.lg)
      .background(
        AppTheme.deepOlive,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
          .stroke(AppTheme.homePanelStroke, lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.colorDeep, radius: 12, x: 0, y: 6)
      .rotationEffect(.degrees(1.5), anchor: .topTrailing)
      .frame(width: UIScreen.main.bounds.width * 0.52)
      .offset(x: UIScreen.main.bounds.width * 0.32, y: 50)
    }
    .frame(height: 190)
  }

  // MARK: - Insight Section (card-free)

  private func insightSection(snapshot: HomeDashboardSnapshot) -> some View {
    let profile = snapshot.healthProfile ?? .default
    let slices = macroSlices(for: profile)

    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Insights")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text(insightMode == .macros ? "Target macro split" : "Weekly cooking cadence")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        Image(systemName: insightMode == .macros ? "chart.pie.fill" : "chart.bar.fill")
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 16, weight: .medium))
      }

      Picker("Insight mode", selection: $insightMode) {
        ForEach(InsightMode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if insightMode == .macros {
        ZStack {
          Chart(slices) { slice in
            SectorMark(
              angle: .value("Percent", slice.value),
              innerRadius: .ratio(0.68),
              angularInset: 2.0
            )
            .foregroundStyle(color(for: slice.color))
            .cornerRadius(4)
          }
          .chartLegend(.hidden)
          .frame(height: 190)

          VStack(spacing: AppTheme.Space.xxxs) {
            Text("\(profile.dailyCalories ?? HealthProfile.default.dailyCalories ?? 2000)")
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
            Text("daily target")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        HStack(spacing: AppTheme.Space.sm) {
          legendChip(title: "Protein", color: AppTheme.chartProtein)
          legendChip(title: "Carbs", color: AppTheme.chartCarbs)
          legendChip(title: "Fat", color: AppTheme.chartFat)
        }
      } else {
        Chart(snapshot.weekdayDistribution) { point in
          BarMark(
            x: .value("Day", point.weekdayLabel),
            y: .value("Meals", point.meals)
          )
          .foregroundStyle(
            .linearGradient(
              colors: [AppTheme.chartBarBottom, AppTheme.chartBarTop],
              startPoint: .bottom,
              endPoint: .top
            )
          )
          .cornerRadius(5)
        }
        .chartYAxis {
          AxisMarks(values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 3]))
              .foregroundStyle(AppTheme.oat.opacity(0.20))
          }
        }
        .chartXAxis {
          AxisMarks { value in
            AxisValueLabel {
              if let label = value.as(String.self) {
                Text(label)
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
          }
        }
        .frame(height: 180)
      }
    }
  }

  // MARK: - Starter Panel

  private func starterPanel(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "sparkles")
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 18))
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Getting Started")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Unlock richer analytics")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }

      Text("Log at least 3 meals to activate macro and cadence insights.")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)

      HStack(spacing: AppTheme.Space.md) {
        FLStatDisplay(value: "\(snapshot.totalMealsCooked)", label: "logged")
        FLStatDisplay(value: "\(max(0, 3 - snapshot.totalMealsCooked))", label: "to unlock")
      }

      FLWaveDivider()
    }
  }

  // MARK: - Secondary Actions

  private func secondaryActions(snapshot: HomeDashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      if !snapshot.hasOnboarded {
        Button(action: onCompleteProfile) {
          Label("Complete profile for personalized recipes", systemImage: "person.badge.plus")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
      }
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

  // MARK: - Helpers

  private func macroSlices(for profile: HealthProfile) -> [MacroTargetSlice] {
    [
      MacroTargetSlice(name: "Protein", value: profile.proteinPct * 100, color: .protein),
      MacroTargetSlice(name: "Carbs", value: profile.carbsPct * 100, color: .carbs),
      MacroTargetSlice(name: "Fat", value: profile.fatPct * 100, color: .fat),
    ]
  }

  private func color(for token: MacroTargetSlice.ColorToken) -> Color {
    switch token {
    case .protein: return AppTheme.chartProtein
    case .carbs: return AppTheme.chartCarbs
    case .fat: return AppTheme.chartFat
    }
  }

  private func legendChip(title: String, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(title)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }

  // MARK: - Reset Footer

  private var resetFooter: some View {
    VStack(spacing: AppTheme.Space.xxs) {
      Rectangle()
        .fill(AppTheme.oat.opacity(0.22))
        .frame(width: 32, height: 1)

      HStack(spacing: 0) {
        Button {
          showResetConfirmation = true
        } label: {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: 9, weight: .semibold))
            Text("Reset progress")
              .font(.system(size: 10, weight: .medium, design: .serif))
              .kerning(0.6)
          }
          .foregroundStyle(AppTheme.dustyRose.opacity(0.65))
          .padding(.horizontal, AppTheme.Space.sm)
          .padding(.vertical, AppTheme.Space.xxs)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset all progress and data")

        if !tutorialProgress.isComplete {
          Text("\u{00B7}")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(AppTheme.oat.opacity(0.30))

          Button {
            showSkipConfirmation = true
          } label: {
            Text("Skip tour")
              .font(.system(size: 9.5, weight: .regular, design: .serif))
              .kerning(0.4)
              .foregroundStyle(AppTheme.textSecondary.opacity(0.45))
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.xxs)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Skip guided tour, not recommended")
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}
