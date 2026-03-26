import Charts
import SwiftUI

/// Post-onboarding Dashboard. Replaces ProfileView once all 4 tutorial quests are completed.
/// Shows today's macro progress, weekly calorie chart, and a recipe book preview.
///
/// When `isTabEmbedded` is true, the parent provides the NavigationStack, so this
/// view omits its own wrapper and Done toolbar, and navigates to RecipeBookView via push.
struct DashboardView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  var isTabEmbedded: Bool = false

  @State private var vm: DashboardViewModel?
  @State private var showEditProfile = false
  @State private var showRecipeBook = false
  @State private var showReverseScan = false

  var body: some View {
    if isTabEmbedded {
      mainContent
    } else {
      NavigationStack {
        mainContent
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { dismiss() }
            }
          }
      }
    }
  }

  // MARK: - Main Content

  @ViewBuilder
  private var mainContent: some View {
    Group {
      if let vm, !vm.isLoading, let snap = vm.snapshot {
        scrollContent(vm: vm, snap: snap)
      } else {
        loadingState
      }
    }
    .navigationTitle("Dashboard")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .sheet(isPresented: $showEditProfile) {
      OnboardingView(isRequired: false) {
        Task { await vm?.load() }
      }
      .environmentObject(deps)
    }
    .navigationDestination(isPresented: $showRecipeBook) {
      RecipeBookView(isPushed: true)
        .environmentObject(deps)
    }
    .navigationDestination(isPresented: $showReverseScan) {
      ReverseScanMealView()
        .environmentObject(deps)
    }
    .refreshable {
      await vm?.load()
    }
    .task {
      let viewModel = DashboardViewModel(
        userDataRepository: deps.userDataRepository,
        personalizationService: deps.personalizationService,
        appleHealthService: deps.appleHealthService
      )
      vm = viewModel
      await viewModel.load()
    }
  }

  // MARK: - Loading

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      FLAnalyzingPulse()
        .frame(width: 44, height: 44)
      Text("Loading your dashboard...")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Main Scroll Content

  private func scrollContent(vm: DashboardViewModel, snap: DashboardSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {

        heroHeader(vm: vm, snap: snap)
          .padding(.bottom, AppTheme.Space.md)

        FLSectionHeader("Today's Macros", icon: "chart.pie")
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.xs)

        todayMacroCard(vm: vm, snap: snap)
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.md)

        FLSectionHeader("This Week", subtitle: "Daily calorie intake", icon: "chart.bar.fill")
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.xs)

        weeklyCalorieChart(vm: vm, snap: snap)
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.md)

        FLSectionHeader("Recipe Book", subtitle: "Your cooking journal", icon: "book.closed.fill")
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.xs)

        recipeBookPreview(snap: snap)
          .padding(.bottom, AppTheme.Space.md)

        FLSecondaryButton("Reverse Scan a Meal", systemImage: "camera.macro") {
          showReverseScan = true
        }
        .flPagePadding()
        .padding(.bottom, AppTheme.Space.md)

        FLWaveDivider()
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.md)

        statsRow(snap: snap)
          .flPagePadding()
          .padding(.bottom, AppTheme.Space.md)

        FLSecondaryButton("Edit Profile", systemImage: "pencil") {
          showEditProfile = true
        }
        .flPagePadding()
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }
      .padding(.top, AppTheme.Space.xs)
    }
  }

  // MARK: - Hero Header

  private func heroHeader(vm: DashboardViewModel, snap: DashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text(snap.healthProfile.goal.displayName)
            .font(.system(size: 26, weight: .bold, design: .serif))
            .foregroundStyle(AppTheme.textPrimary)

          Text("\(Int(vm.dailyCalorieGoal.rounded())) cal / day")
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        calorieRing(vm: vm, snap: snap)
      }

      let badges = snap.healthProfile.activeDietaryBadges
      if !badges.isEmpty || snap.currentStreak > 0 {
        HStack(spacing: AppTheme.Space.xs) {
          if snap.currentStreak > 0 {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: "flame.fill")
                .font(.system(size: 11))
              Text("\(snap.currentStreak)d")
                .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.xxs)
            .background(
              AppTheme.accentMuted,
              in: Capsule()
            )
          }

          ForEach(badges, id: \.self) { badge in
            Text(badge)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.sage)
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxs)
              .background(
                AppTheme.sage.opacity(0.12),
                in: Capsule()
              )
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .flPagePadding()
  }

  private func calorieRing(vm: DashboardViewModel, snap: DashboardSnapshot) -> some View {
    let consumed = Int(snap.todayMacros.calories.rounded())
    let goal = Int(vm.dailyCalorieGoal.rounded())

    return ZStack {
      Circle()
        .stroke(AppTheme.surfaceMuted, lineWidth: 8)
      Circle()
        .trim(from: 0, to: vm.todayCaloriePct)
        .stroke(
          AppTheme.accent,
          style: StrokeStyle(lineWidth: 8, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(AppMotion.chartReveal, value: vm.todayCaloriePct)

      VStack(spacing: 0) {
        Text("\(consumed)")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())
        Text("/ \(goal)")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .frame(width: 68, height: 68)
  }

  // MARK: - Today's Macros Card

  private func todayMacroCard(vm: DashboardViewModel, snap: DashboardSnapshot) -> some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        macroProgressRow(
          label: "Protein",
          current: snap.todayMacros.protein,
          goal: vm.dailyProteinGoalGrams,
          unit: "g",
          color: AppTheme.chartProtein
        )
        macroProgressRow(
          label: "Carbs",
          current: snap.todayMacros.carbs,
          goal: vm.dailyCarbsGoalGrams,
          unit: "g",
          color: AppTheme.chartCarbs
        )
        macroProgressRow(
          label: "Fat",
          current: snap.todayMacros.fat,
          goal: vm.dailyFatGoalGrams,
          unit: "g",
          color: AppTheme.chartFat
        )
      }
    }
  }

  private func macroProgressRow(
    label: String,
    current: Double,
    goal: Double,
    unit: String,
    color: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack {
        Text(label)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text("\(Int(current.rounded()))\(unit) / \(Int(goal.rounded()))\(unit)")
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
      }
      GeometryReader { geo in
        let pct = goal > 0 ? min(current / goal, 1.0) : 0
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(height: 8)
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: geo.size.width * pct, height: 8)
            .animation(AppMotion.chartReveal, value: pct)
        }
      }
      .frame(height: 8)
    }
  }

  // MARK: - Weekly Calorie Chart

  private func weeklyCalorieChart(vm: DashboardViewModel, snap: DashboardSnapshot) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        if snap.weeklyMacros.isEmpty {
          Text("Cook a meal to start tracking!")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, AppTheme.Space.xl)
        } else {
          Chart {
            ForEach(snap.weeklyMacros) { point in
              BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Calories", point.calories)
              )
              .foregroundStyle(
                .linearGradient(
                  colors: [AppTheme.chartBarBottom, AppTheme.chartBarTop],
                  startPoint: .bottom,
                  endPoint: .top
                )
              )
              .cornerRadius(4)
            }

            RuleMark(y: .value("Goal", vm.dailyCalorieGoal))
              .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
              .foregroundStyle(AppTheme.chartLine.opacity(0.6))
              .annotation(position: .top, alignment: .trailing) {
                Text("Goal")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.chartLine)
              }
          }
          .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
              AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .chartYAxis {
            AxisMarks(position: .leading) { _ in
              AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(AppTheme.oat.opacity(0.3))
              AxisValueLabel()
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .frame(height: 180)
        }
      }
    }
  }

  // MARK: - Recipe Book Preview

  private func recipeBookPreview(snap: DashboardSnapshot) -> some View {
    VStack(spacing: AppTheme.Space.sm) {
      if snap.recentJournal.isEmpty {
        FLEmptyState(
          title: "No Recipes Yet",
          message: "Cook your first meal and it will appear here in your recipe book.",
          systemImage: "book.closed"
        )
        .flPagePadding()
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.sm) {
            ForEach(snap.recentJournal) { entry in
              journalEntryCard(entry: entry)
            }
          }
          .padding(.horizontal, AppTheme.Space.page)
        }

        Button {
          showRecipeBook = true
        } label: {
          HStack(spacing: AppTheme.Space.xxs) {
            Text("See All Recipes")
              .font(AppTheme.Typography.label)
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
          }
          .foregroundStyle(AppTheme.accent)
        }
        .flPagePadding()
      }
    }
  }

  private func journalEntryCard(entry: CookingJournalEntry) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Group {
        if let imagePath = entry.imagePath,
          let image = deps.imageStorageService.load(relativePath: imagePath)
        {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          ZStack {
            AppTheme.surfaceMuted
            Image(systemName: "fork.knife")
              .font(.system(size: 22))
              .foregroundStyle(AppTheme.oat)
          }
        }
      }
      .frame(width: 130, height: 100)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

      Text(entry.recipe.title)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textPrimary)
        .lineLimit(2)

      if let rating = entry.rating, rating > 0 {
        HStack(spacing: 2) {
          ForEach(1...5, id: \.self) { star in
            Image(systemName: star <= rating ? "star.fill" : "star")
              .font(.system(size: 10))
              .foregroundStyle(star <= rating ? AppTheme.accent : AppTheme.oat.opacity(0.3))
          }
        }
      }

      Text("\(Int(entry.macrosConsumed.calories.rounded())) cal")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(width: 130)
  }

  // MARK: - Stats Row

  private func statsRow(snap: DashboardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      Text("BY THE NUMBERS")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      HStack(spacing: 0) {
        FLStatDisplay(value: "\(snap.currentStreak)", label: "day streak")
        statDivider
        FLStatDisplay(value: "\(snap.totalMealsCooked)", label: "total meals")
        statDivider
        FLStatDisplay(value: "\(snap.totalRecipesUsed)", label: "recipes used")
      }

      if let avg = snap.averageRating {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "star.fill")
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.accent)
          Text(String(format: "%.1f", avg))
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("avg rating")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  private var statDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.30))
      .frame(width: 1, height: AppTheme.Home.statDividerHeight)
  }
}
