import SwiftUI

struct HomeGraduatedEditorialHeader: View {
  let timeGreeting: String
  let editorialDate: String
  let onCompleteProfile: () -> Void

  var body: some View {
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
}

struct HomeGraduatedHeroSection: View {
  let heroAppeared: Bool
  let onDemoMode: () -> Void

  var body: some View {
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
}

struct HomeFloatingStatsSection: View {
  let snapshot: HomeDashboardSnapshot

  var body: some View {
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
}

struct HomeMyRhythmSection: View {
  let snapshot: HomeDashboardSnapshot

  var body: some View {
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
}

struct HomeFridgeLuckPanelsSection: View {
  let snapshot: HomeDashboardSnapshot

  var body: some View {
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
}

struct HomeUseSoonSection: View {
  let suggestions: [InventoryUseSoonSuggestion]

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(AppTheme.warning)
        Text("Use Soon")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
      }

      if suggestions.isEmpty {
        Text("No urgent items right now.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      } else {
        VStack(spacing: AppTheme.Space.xs) {
          ForEach(suggestions, id: \.ingredientId) { suggestion in
            HStack(spacing: AppTheme.Space.sm) {
              VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
                Text(suggestion.ingredientName)
                  .font(AppTheme.Typography.bodyMedium)
                  .foregroundStyle(AppTheme.textPrimary)
                Text("\(Int(suggestion.remainingGrams.rounded()))g left")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }

              Spacer()

              Text(dayLabel(for: suggestion.daysRemaining))
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.warning)
                .padding(.horizontal, AppTheme.Space.xs)
                .padding(.vertical, AppTheme.Space.chipVertical)
                .background(AppTheme.warning.opacity(0.10), in: Capsule())
            }
            .padding(.vertical, AppTheme.Space.xs)

            if suggestion.ingredientId != suggestions.last?.ingredientId {
              Divider()
            }
          }
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

  private func dayLabel(for days: Int) -> String {
    if days <= 0 { return "Today" }
    if days == 1 { return "1 day" }
    return "\(days) days"
  }
}

struct HomeStarterPanelSection: View {
  let snapshot: HomeDashboardSnapshot

  var body: some View {
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
}

struct HomeSecondaryActionsSection: View {
  let snapshot: HomeDashboardSnapshot
  let onCompleteProfile: () -> Void

  var body: some View {
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
}
