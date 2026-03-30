import SwiftUI

struct ProgressTabView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let deps: AppDependencies
  let onOpenProfileSettings: () -> Void

  @State private var viewModel: ProgressViewModel
  @State private var headerAppeared = false
  @State private var showRecipeBook = false
  @State private var showReverseScan = false

  init(deps: AppDependencies, onOpenProfileSettings: @escaping () -> Void) {
    self.deps = deps
    self.onOpenProfileSettings = onOpenProfileSettings
    _viewModel = State(
      wrappedValue: ProgressViewModel(
        userDataRepository: deps.userDataRepository,
        personalizationService: deps.personalizationService,
        appleHealthService: deps.appleHealthService
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
    .refreshable {
      await viewModel.load()
    }
    .task {
      guard viewModel.snapshot == nil else { return }
      await viewModel.load()
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
          goalLabel: snapshot.healthProfile.goal.displayName
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.md)

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

        ProgressRecentMealsSection(recentJournal: snapshot.recentJournal)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressSavedWinnersSection(winners: snapshot.savedWinners)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        ProgressWeeklyTrendSection(
          weeklyMacros: snapshot.weeklyMacros,
          dailyCalorieGoal: viewModel.dailyCalorieGoal,
          insightText: viewModel.weeklyInsight,
          onRangeChanged: { range in
            await viewModel.loadMacros(for: range)
            return viewModel.rangeMacros
          }
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.sectionBreak)

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
      FLSecondaryButton("Reverse Scan a Meal", systemImage: "camera.macro") {
        showReverseScan = true
      }

      if snapshot.hasOnboarded {
        FLSecondaryButton("Edit Profile", systemImage: "pencil") {
          onOpenProfileSettings()
        }
      }
    }
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
