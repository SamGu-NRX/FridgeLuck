import SwiftUI

struct RecipeResultsContextHeader: View {
  let ingredientCount: Int
  let policySummary: String
  let activeDietaryBadges: [String]
  let exactCount: Int
  let nearCount: Int
  let quickSuggestionMinutes: Int?
  let aiNotice: String?

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("Based on \(ingredientCount) ingredient\(ingredientCount == 1 ? "" : "s")")
        .font(AppTheme.Typography.displaySmall)
        .foregroundStyle(AppTheme.textPrimary)

      Text(policySummary)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)

      if !activeDietaryBadges.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.xs) {
            ForEach(activeDietaryBadges, id: \.self) { badge in
              statusChip(label: badge, icon: "line.3.horizontal.decrease.circle")
            }
          }
        }
      }

      if exactCount > 0 || nearCount > 0 {
        HStack(spacing: AppTheme.Space.sm) {
          statusChip(label: "\(exactCount) exact", icon: "checkmark.circle")
          if nearCount > 0 {
            statusChip(label: "\(nearCount) near", icon: "exclamationmark.circle")
          }
          if let quickSuggestionMinutes {
            statusChip(label: "\(quickSuggestionMinutes)m", icon: "bolt.fill")
          }
        }
      }

      if let aiNotice {
        Text(aiNotice)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func statusChip(label: String, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: icon)
      Text(label)
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }
}

struct RecipeResultsLoadingView: View {
  var body: some View {
    VStack(spacing: AppTheme.Space.md) {
      FLAnalyzingPulse()
        .frame(width: 48, height: 48)
      Text("Finding recipes...")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)
      Text("Scoring by ingredient match, nutrition profile, and personalization.")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xxl)
  }
}

struct RecipeResultsBestMatchHero: View {
  let scored: ScoredRecipe
  let transitionNamespace: Namespace.ID
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        HStack {
          Text("BEST MATCH")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white)
            .kerning(1.2)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .background(AppTheme.accent, in: Capsule())
          Spacer()
          HealthBadge(score: scored.healthScore)
        }

        Text(scored.recipe.title)
          .font(AppTheme.Typography.displayMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)

        HStack(spacing: AppTheme.Space.md) {
          Label("\(scored.recipe.timeMinutes) min", systemImage: "clock")
          Label(
            "\(scored.matchedRequired)/\(scored.totalRequired) required",
            systemImage: "checkmark.circle"
          )
          Spacer()
        }
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

        MacroSummaryBar(macros: scored.macros)

        if !scored.rankingReasons.isEmpty {
          Text(scored.rankingReasons.joined(separator: " • "))
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.sm)
      .background(AppTheme.surface)
      .clipShape(
        RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
      )
      .overlay(alignment: .bottom) {
        FLTornEdge(seed: scored.recipe.title.hashValue)
          .fill(AppTheme.bg)
          .frame(height: 8)
          .offset(y: 4)
      }
      .shadow(color: AppTheme.Shadow.color, radius: 12, x: 0, y: 6)
    }
    .matchedTransitionSource(id: "best-match", in: transitionNamespace)
    .buttonStyle(.plain)
    .padding(.horizontal, AppTheme.Space.page)
  }
}

struct RecipeResultsExactGridSection: View {
  let exactMatches: [ScoredRecipe]
  let revealedCount: Int
  let reduceMotion: Bool
  let transitionNamespace: Namespace.ID
  let onTap: (ScoredRecipe) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("EXACT MATCHES")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.2)

      let columns = [
        GridItem(.flexible(), spacing: AppTheme.Space.sm),
        GridItem(.flexible(), spacing: AppTheme.Space.sm),
      ]

      LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
        ForEach(Array(exactMatches.enumerated()), id: \.element.recipe.id) { index, scored in
          recipeGridItem(scored: scored, index: index)
            .opacity(index <= revealedCount ? 1 : 0)
            .offset(y: index <= revealedCount ? 0 : 12)
            .animation(
              reduceMotion ? nil : AppMotion.gentle.delay(Double(index) * AppMotion.staggerDelay),
              value: revealedCount
            )
        }
      }
    }
  }

  private func recipeGridItem(scored: ScoredRecipe, index: Int) -> some View {
    let isOdd = index % 2 == 1

    return Button {
      onTap(scored)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Text("\(scored.matchedRequired)/\(scored.totalRequired)")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.accent)

        Text(scored.recipe.title)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "clock")
          Text("\(scored.recipe.timeMinutes)m")
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          miniMacro("P", value: Int(scored.macros.proteinPerServing), color: AppTheme.sage)
          miniMacro("C", value: Int(scored.macros.carbsPerServing), color: AppTheme.oat)
          miniMacro("F", value: Int(scored.macros.fatPerServing), color: AppTheme.accentLight)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .frame(minHeight: isOdd ? 180 : 160)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 6, x: 0, y: 3)
      .offset(y: isOdd ? 16 : 0)
    }
    .matchedTransitionSource(id: transitionID(for: scored), in: transitionNamespace)
    .buttonStyle(.plain)
  }

  private func miniMacro(_ label: String, value: Int, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text("\(label) \(value)g")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private func transitionID(for scored: ScoredRecipe) -> String {
    let id = scored.recipe.id ?? -1
    return "recipe-card-\(id)"
  }
}

struct RecipeResultsNearMatchSection: View {
  let nearMatches: [ScoredRecipe]
  let onTap: (ScoredRecipe) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("ALMOST THERE")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.2)

      ForEach(nearMatches) { scored in
        Button {
          onTap(scored)
        } label: {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text(scored.recipe.title)
              .font(.system(.headline, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)
              .multilineTextAlignment(.leading)

            HStack(spacing: AppTheme.Space.md) {
              Label("\(scored.recipe.timeMinutes)m", systemImage: "clock")
              Label("Missing \(scored.missingRequiredCount)", systemImage: "exclamationmark.circle")
            }
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)

            if !scored.missingIngredientIds.isEmpty {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Space.xs) {
                  ForEach(scored.missingIngredientIds, id: \.self) { ingredientID in
                    Text(IngredientLexicon.displayName(for: ingredientID))
                      .font(AppTheme.Typography.labelSmall)
                      .foregroundStyle(AppTheme.textSecondary)
                      .padding(.horizontal, AppTheme.Space.sm)
                      .padding(.vertical, AppTheme.Space.chipVertical)
                      .background(AppTheme.surfaceMuted, in: Capsule())
                  }
                }
              }
            }

            if !scored.rankingReasons.isEmpty {
              Text(scored.rankingReasons.joined(separator: " • "))
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
      }
    }
  }
}

struct HealthBadge: View {
  let score: HealthScore

  var body: some View {
    HStack(spacing: AppTheme.Space.xxxs) {
      ForEach(1...5, id: \.self) { star in
        Image(systemName: star <= score.rating ? "star.fill" : "star")
          .font(.system(size: 10))
          .foregroundStyle(star <= score.rating ? AppTheme.accent : AppTheme.oat.opacity(0.40))
          .animation(.default, value: star <= score.rating)
      }
    }
  }
}

struct MacroSummaryBar: View {
  let macros: RecipeMacros

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      macroItem("Cal", value: "\(Int(macros.caloriesPerServing))", color: AppTheme.accent)
      macroItem("P", value: "\(Int(macros.proteinPerServing))g", color: AppTheme.sage)
      macroItem("C", value: "\(Int(macros.carbsPerServing))g", color: AppTheme.oat)
      macroItem("F", value: "\(Int(macros.fatPerServing))g", color: AppTheme.accentLight)
      Spacer()
    }
  }

  private func macroItem(_ label: String, value: String, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xxxs) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(label) \(value)")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }
}
