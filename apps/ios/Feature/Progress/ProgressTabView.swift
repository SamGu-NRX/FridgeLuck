import SwiftUI

struct ProgressTabView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let deps: AppDependencies
  let onOpenProfileSettings: () -> Void

  @State private var viewModel: ProgressViewModel
  @State private var headerAppeared = false
  @State private var showRecipeBook = false
  @State private var showReverseScan = false
  @State private var showJournalDetail = false
  @State private var journalDetailEntry: CookingJournalEntry?
  @State private var showProvenanceNotes = false

  init(deps: AppDependencies, onOpenProfileSettings: @escaping () -> Void) {
    self.deps = deps
    self.onOpenProfileSettings = onOpenProfileSettings
    _viewModel = State(
      wrappedValue: ProgressViewModel(
        userDataRepository: deps.userDataRepository,
        personalizationService: deps.personalizationService,
        appleHealthService: deps.appleHealthService,
        database: deps.appDatabase
      )
    )
  }

  var body: some View {
    Group {
      if let snapshot = viewModel.snapshot {
        scrollContent(snapshot: snapshot)
      } else if viewModel.isLoading {
        loadingState
      } else if viewModel.errorMessage != nil {
        errorState
      } else {
        loadingState
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .navigationDestination(isPresented: $showRecipeBook) {
      RecipeBookView(isPushed: true)
        .environmentObject(deps)
    }
    .navigationDestination(isPresented: $showReverseScan) {
      ReverseScanMealView()
        .environmentObject(deps)
    }
    .navigationDestination(isPresented: $showJournalDetail) {
      if let journalDetailEntry {
        RecipeJournalDetailView(entry: journalDetailEntry, isPushed: true)
          .environmentObject(deps)
      }
    }
    .refreshable {
      await viewModel.load()
      viewModel.refreshTrend()
    }
    .task {
      guard viewModel.snapshot == nil else { return }
      await viewModel.load()
      // First trend load through the owned coordinator; subsequent loads
      // are revision-driven or user-selected.
      viewModel.selectRange(.week)
    }
  }

  private func scrollContent(snapshot: ProgressSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.md)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressCalorieHero(
          consumed: snapshot.todayMacros.calories,
          goal: viewModel.dailyCalorieGoal,
          goalLabel: viewModel.goalTarget?.goalName ?? snapshot.healthProfile.goal.displayName,
          goalIsSuggested: viewModel.goalTarget?.provenance == .suggestedTarget
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.xs)

        // On-demand provenance notes (R4): where today's numbers and the
        // target come from. Hidden until asked for.
        if let today = viewModel.todayReading, let target = viewModel.goalTarget {
          provenanceDisclosure(
            text: "\(ProgressSourceNotes.todayNote(reading: today)) \(ProgressSourceNotes.goalNote(target: target))"
          )
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.md)
        }

        ProgressMacroRow(
          todayMacros: snapshot.todayMacros,
          proteinGoal: viewModel.dailyProteinGoalGrams,
          carbsGoal: viewModel.dailyCarbsGoalGrams,
          fatGoal: viewModel.dailyFatGoalGrams
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.md)

        ProgressMacroDetailCard(
          todayMacros: snapshot.todayMacros,
          proteinGoal: viewModel.dailyProteinGoalGrams,
          carbsGoal: viewModel.dailyCarbsGoalGrams,
          fatGoal: viewModel.dailyFatGoalGrams
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressRecentMealsSection(
          recentJournal: snapshot.recentJournal,
          onTapMeal: { entry in
            // Journal editing stays with its owner: the existing journal
            // detail screen. Progress never presents its own editor.
            switch ProgressFlowPolicy.mealRoute(for: entry) {
            case .journalDetail:
              journalDetailEntry = entry
              showJournalDetail = true
            }
          }
        )
        .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressSavedWinnersSection(winners: snapshot.savedWinners)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressWeeklyTrendSection(
          state: viewModel.rangeState,
          dailyCalorieGoal: viewModel.dailyCalorieGoal,
          insightText: viewModel.weeklyInsight,
          onSelect: { viewModel.selectRange($0) }
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.xs)

        if let shown = viewModel.rangeState.shown {
          provenanceDisclosure(text: ProgressSourceNotes.rangeNote(reading: shown))
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)
        }

        ProgressStatsSection(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        FLWaveDivider()
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.md)

        actionsSection(snapshot: snapshot)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(
            .bottom,
            AppTheme.Space.bottomClearance + AppTheme.Home.navOrbLift + AppTheme.Home.navBaseOffset)
      }
    }
  }

  private func header(snapshot: ProgressSnapshot) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text("Progress")
          .font(AppTheme.Typography.displayLarge)
          .foregroundStyle(AppTheme.textPrimary)

        Text("Your meals and nutrition")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .opacity(headerAppeared ? 1 : 0)
      .offset(y: headerAppeared ? 0 : 8)

      Spacer()

      if snapshot.currentStreak > 0 {
        FLStreakBadge(
          currentStreak: snapshot.currentStreak,
          weekActivity: snapshot.weekActivity,
          isMilestone: FLStreakBadge.milestoneThresholds.contains(snapshot.currentStreak)
        )
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : 8)
      }
    }
    .onAppear {
      if reduceMotion {
        headerAppeared = true
      } else {
        withAnimation(AppMotion.tabEntrance) {
          headerAppeared = true
        }
      }
    }
  }

  private func actionsSection(snapshot: ProgressSnapshot) -> some View {
    VStack(spacing: AppTheme.Space.sm) {
      // Entry-point convention (open PR 35): the meal-logging entry is
      // "Log a Meal" with fork.knife and an explicit label — never
      // "Reverse Scan a Meal" / camera.macro.
      FLSecondaryButton("Log a Meal", systemImage: "fork.knife") {
        showReverseScan = true
      }
      .accessibilityLabel("Log a meal")

      if ProgressFlowPolicy.canOfferGoalEditing(hasOnboarded: snapshot.hasOnboarded) {
        FLSecondaryButton("Edit Profile", systemImage: "pencil") {
          onOpenProfileSettings()
        }
      }
    }
  }

  /// Disclosure row for on-demand provenance notes.
  private func provenanceDisclosure(text: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          showProvenanceNotes.toggle()
        }
      } label: {
        Label(
          showProvenanceNotes ? "Hide where these numbers come from" : "Where do these numbers come from?",
          systemImage: "info.circle"
        )
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Shows the data source for these cards")

      if showProvenanceNotes {
        Text(text)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Loading / Error

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      FLAnalyzingPulse()
        .frame(width: 44, height: 44)
      Text("Loading your progress...")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var errorState: some View {
    FLEmptyState(
      title: "Couldn't load progress",
      message: viewModel.errorMessage ?? "Please try again.",
      systemImage: "exclamationmark.triangle.fill",
      actionTitle: "Retry",
      action: { Task { await viewModel.load() } }
    )
    .padding(.horizontal, AppTheme.Space.page)
  }
}
