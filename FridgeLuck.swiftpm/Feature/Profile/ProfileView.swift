import SwiftUI

/// Read-focused profile view.
/// Journal-style layout: large serif headlines, overlapping shapes, wave dividers, no cards.
struct ProfileView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  @State private var profile: HealthProfile = .default
  @State private var totalMeals: Int = 0
  @State private var totalRecipes: Int = 0
  @State private var streak: Int = 0
  @State private var allergenIngredients: [Ingredient] = []
  @State private var showEditProfile = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          goalHeader
            .padding(.bottom, AppTheme.Space.sectionBreak)

          calorieDisplay
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          macroCircles
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          dietarySection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          allergenSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          statsSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          editButton
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.bottomClearance)
        }
        .padding(.top, AppTheme.Space.lg)
      }
      .navigationTitle("Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .flPageBackground()
      .sheet(isPresented: $showEditProfile) {
        OnboardingView(isRequired: false) {
          Task { await loadProfile() }
        }
        .environmentObject(deps)
      }
      .task {
        await loadProfile()
      }
    }
  }

  // MARK: - Goal Header (display-size serif title)

  private var goalHeader: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text("YOUR GOAL")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      Text(profile.goal.displayName)
        .font(.system(size: 42, weight: .bold, design: .serif))
        .foregroundStyle(AppTheme.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.vertical, AppTheme.Space.lg)
    .background(
      LinearGradient(
        colors: [AppTheme.bg, AppTheme.surfaceMuted.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  // MARK: - Calorie Display (massive serif number)

  private var calorieDisplay: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text("\(profile.dailyCalories ?? 2000)")
        .font(.system(size: 64, weight: .bold, design: .serif))
        .foregroundStyle(AppTheme.accent)
        .contentTransition(.numericText())

      Text("daily calorie target")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  // MARK: - Macro Circles (Venn-diagram style, overlapping)

  private var macroCircles: some View {
    let proteinPct = Int((profile.proteinPct * 100).rounded())
    let carbsPct = Int((profile.carbsPct * 100).rounded())
    let fatPct = Int((profile.fatPct * 100).rounded())

    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("MACRO SPLIT")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      ZStack {
        Circle()
          .fill(AppTheme.chartProtein.opacity(0.20))
          .frame(width: 100, height: 100)
          .overlay(
            VStack(spacing: AppTheme.Space.xxxs) {
              Text("\(proteinPct)%")
                .font(AppTheme.Typography.dataMedium)
              Text("Protein")
                .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(AppTheme.chartProtein)
          )
          .offset(x: -44, y: 0)

        Circle()
          .fill(AppTheme.chartCarbs.opacity(0.20))
          .frame(width: 100, height: 100)
          .overlay(
            VStack(spacing: AppTheme.Space.xxxs) {
              Text("\(carbsPct)%")
                .font(AppTheme.Typography.dataMedium)
              Text("Carbs")
                .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(AppTheme.chartCarbs)
          )
          .offset(x: 10, y: -14)

        Circle()
          .fill(AppTheme.chartFat.opacity(0.20))
          .frame(width: 88, height: 88)
          .overlay(
            VStack(spacing: AppTheme.Space.xxxs) {
              Text("\(fatPct)%")
                .font(AppTheme.Typography.dataMedium)
              Text("Fat")
                .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(AppTheme.chartFat)
          )
          .offset(x: 58, y: 18)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 120)
    }
  }

  // MARK: - Dietary Section

  private var dietarySection: some View {
    let restrictions = profile.parsedDietaryRestrictions

    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("DIETARY PREFERENCES")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      if restrictions.isEmpty {
        Text("No dietary restrictions set.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      } else {
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(restrictions, id: \.self) { restriction in
            Text(restriction.replacingOccurrences(of: "_", with: " ").capitalized)
              .font(AppTheme.Typography.label)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.chipVertical)
              .foregroundStyle(AppTheme.sage)
              .background(AppTheme.sage.opacity(0.12), in: Capsule())
          }
        }
      }
    }
  }

  // MARK: - Allergen Section (organic blob shapes)

  private var allergenSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("ALLERGEN SAFETY")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      if allergenIngredients.isEmpty {
        Text("No allergens flagged.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      } else {
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(Array(allergenIngredients.prefix(30)), id: \.id) { ingredient in
            Text(ingredient.displayName)
              .font(AppTheme.Typography.bodySmall)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.chipVertical)
              .foregroundStyle(AppTheme.accent)
              .background(
                FLOrganicBlob(seed: ingredient.displayName.hashValue)
                  .fill(AppTheme.accent.opacity(0.10))
              )
          }
        }
      }
    }
  }

  // MARK: - Stats (editorial "by the numbers")

  private var statsSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      Text("BY THE NUMBERS")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      HStack(spacing: 0) {
        editorialStat(value: "\(streak)", label: "day streak")
        thinDivider
        editorialStat(value: "\(totalMeals)", label: "total meals")
        thinDivider
        editorialStat(value: "\(totalRecipes)", label: "recipes used")
      }
    }
  }

  private func editorialStat(value: String, label: String) -> some View {
    VStack(spacing: AppTheme.Space.xxxs) {
      Text(value)
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)
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

  // MARK: - Edit Button

  private var editButton: some View {
    FLSecondaryButton("Edit Profile", systemImage: "pencil") {
      showEditProfile = true
    }
  }

  // MARK: - Data Loading

  private func loadProfile() async {
    do {
      profile = try deps.userDataRepository.fetchHealthProfile()
      totalMeals = try deps.userDataRepository.totalMealsCooked()
      totalRecipes = try deps.userDataRepository.totalRecipesUsed()

      let days = try deps.userDataRepository.mealsByDay(lastDays: 30)
      streak = calculateStreak(from: days)

      let allIngredients = (try? deps.ingredientRepository.fetchAll()) ?? []
      let allergenIds = Set(profile.parsedAllergenIds)
      allergenIngredients = allIngredients.filter { ingredient in
        guard let id = ingredient.id else { return false }
        return allergenIds.contains(id)
      }.sorted { $0.displayName < $1.displayName }
    } catch {}
  }

  private func calculateStreak(from days: [DailyCookingPoint]) -> Int {
    var count = 0
    for day in days.reversed() {
      if day.meals > 0 {
        count += 1
      } else {
        break
      }
    }
    return count
  }
}
