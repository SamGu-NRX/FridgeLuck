import SwiftUI

/// Journal-style detail view for a single cooked meal.
/// Shows hero photo, recipe title, date, editable star rating, macro breakdown, and "Cook Again" CTA.
struct RecipeJournalDetailView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  let entry: CookingJournalEntry
  var isPushed: Bool = false

  @State private var rating: Int
  @State private var hasChangedRating = false

  init(entry: CookingJournalEntry, isPushed: Bool = false) {
    self.entry = entry
    self.isPushed = isPushed
    self._rating = State(initialValue: entry.rating ?? 0)
  }

  var body: some View {
    if isPushed {
      mainContent
    } else {
      NavigationStack {
        mainContent
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") {
                saveRatingIfNeeded()
                dismiss()
              }
            }
          }
      }
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {

        heroPhoto
          .padding(.bottom, AppTheme.Space.lg)

        titleSection
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        ratingSection
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        FLWaveDivider()
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        macroSection
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        FLWaveDivider()
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        detailsSection
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.sectionBreak)

        FLPrimaryButton("Cook Again", systemImage: "fork.knife") {
          dismiss()
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }
    }
    .navigationTitle("Meal Detail")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .onDisappear {
      saveRatingIfNeeded()
    }
  }

  // MARK: - Hero Photo

  private var heroPhoto: some View {
    Group {
      if let imagePath = entry.imagePath,
        let image = deps.imageStorageService.load(relativePath: imagePath)
      {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity)
          .frame(height: 240)
          .clipped()
      } else {
        ZStack {
          LinearGradient(
            colors: [AppTheme.surfaceMuted, AppTheme.bgDeep],
            startPoint: .top,
            endPoint: .bottom
          )
          VStack(spacing: AppTheme.Space.sm) {
            Image(systemName: "camera")
              .font(.system(size: 32))
              .foregroundStyle(AppTheme.oat)
            Text("No photo taken")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
      }
    }
  }

  // MARK: - Title Section

  private var titleSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text(entry.recipe.title)
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)

      HStack(spacing: AppTheme.Space.sm) {
        Label {
          Text(entry.cookedAt, format: .dateTime.month(.wide).day().year())
            .font(AppTheme.Typography.bodySmall)
        } icon: {
          Image(systemName: "calendar")
            .font(.system(size: 12))
        }
        .foregroundStyle(AppTheme.textSecondary)

        if entry.servingsConsumed > 0 {
          Label {
            Text("\(entry.servingsConsumed) serving\(entry.servingsConsumed == 1 ? "" : "s")")
              .font(AppTheme.Typography.bodySmall)
          } icon: {
            Image(systemName: "person.fill")
              .font(.system(size: 12))
          }
          .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  // MARK: - Rating Section

  private var ratingSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("YOUR RATING")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      FLStarRating(rating: $rating, size: 32)
        .onChange(of: rating) { _, _ in
          hasChangedRating = true
        }

      if rating == 0 {
        Text("Tap a star to rate this meal")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  // MARK: - Macro Section

  private var macroSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("NUTRITION CONSUMED")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      FLCard {
        VStack(spacing: AppTheme.Space.md) {
          HStack {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text("\(Int(entry.macrosConsumed.calories.rounded()))")
                .font(AppTheme.Typography.displayMedium)
                .foregroundStyle(AppTheme.accent)
              Text("calories consumed")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()

            FLMacroRing(
              proteinPct: macroPct(entry.macrosConsumed.protein, factor: 4),
              carbsPct: macroPct(entry.macrosConsumed.carbs, factor: 4),
              fatPct: macroPct(entry.macrosConsumed.fat, factor: 9),
              size: 64,
              lineWidth: 7
            )
          }

          Divider()
            .foregroundStyle(AppTheme.oat.opacity(0.3))

          HStack(spacing: 0) {
            macroColumn(
              label: "Protein",
              grams: entry.macrosConsumed.protein,
              color: AppTheme.chartProtein
            )
            macroColumnDivider
            macroColumn(
              label: "Carbs",
              grams: entry.macrosConsumed.carbs,
              color: AppTheme.chartCarbs
            )
            macroColumnDivider
            macroColumn(
              label: "Fat",
              grams: entry.macrosConsumed.fat,
              color: AppTheme.chartFat
            )
          }
        }
      }
    }
  }

  private func macroColumn(label: String, grams: Double, color: Color) -> some View {
    VStack(spacing: AppTheme.Space.xxxs) {
      Text("\(Int(grams.rounded()))g")
        .font(AppTheme.Typography.dataMedium)
        .foregroundStyle(color)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var macroColumnDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.3))
      .frame(width: 1, height: AppTheme.Home.statDividerHeight)
  }

  private func macroPct(_ grams: Double, factor: Double) -> Double {
    let totalCals = entry.macrosConsumed.calories
    guard totalCals > 0 else { return 0 }
    return min((grams * factor) / totalCals, 1.0)
  }

  // MARK: - Details Section

  private var detailsSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("DETAILS")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      HStack(spacing: AppTheme.Space.lg) {
        detailItem(icon: "clock", label: "Cook time", value: "\(entry.recipe.timeMinutes) min")
        detailItem(
          icon: "person.2", label: "Servings",
          value: "\(entry.recipe.servings)")

        if !entry.recipe.recipeTags.labels.isEmpty {
          detailItem(
            icon: "tag", label: "Style",
            value: entry.recipe.recipeTags.labels.first?.replacingOccurrences(of: "_", with: " ")
              .capitalized ?? "")
        }
      }
    }
  }

  private func detailItem(icon: String, label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Image(systemName: icon)
        .font(.system(size: 14))
        .foregroundStyle(AppTheme.accent)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      Text(value)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .fontWeight(.medium)
    }
  }

  // MARK: - Rating Persistence

  private func saveRatingIfNeeded() {
    guard hasChangedRating, rating > 0 else { return }
    do {
      try deps.userDataRepository.updateRating(historyId: entry.id, rating: rating)
    } catch {
      // Non-critical — rating save is best-effort
    }
  }
}
