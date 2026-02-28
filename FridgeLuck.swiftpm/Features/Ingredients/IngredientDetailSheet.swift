import SwiftUI

/// Educational ingredient card with per-100g nutrition and storage guidance.
struct IngredientDetailSheet: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let ingredient: Ingredient

  @State private var aliases: [String] = []

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          heroSection
          macroSection
          secondaryNutrients
          contextSection
          if !aliases.isEmpty {
            aliasSection
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.vertical, AppTheme.Space.md)
      }
      .navigationTitle("Ingredient")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        loadAliases()
      }
    }
    .flPageBackground()
  }

  private var heroSection: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top, spacing: AppTheme.Space.sm) {
          Image(systemName: spriteSymbolName())
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
            .frame(width: 36, height: 36)
            .background(
              AppTheme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

          VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
            Text(ingredient.displayName)
              .font(AppTheme.Typography.displaySmall)
              .foregroundStyle(AppTheme.textPrimary)
            if let categoryLabel = ingredient.categoryLabel, !categoryLabel.isEmpty {
              Text(categoryLabel.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          Spacer()
        }

        Text("\(Int(ingredient.calories)) kcal per 100g")
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
          .padding(.horizontal, AppTheme.Space.sm)
          .padding(.vertical, AppTheme.Space.xs)
          .background(AppTheme.surface, in: Capsule())

        if let description = ingredient.description, !description.isEmpty {
          Text(description)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        } else {
          Text("USDA reference ingredient. Nutrition values are standardized per 100g.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  private var macroSection: some View {
    HStack(spacing: AppTheme.Space.sm) {
      macroCard(
        "Protein", value: String(format: "%.1f", ingredient.protein), unit: "g", color: .blue)
      macroCard("Carbs", value: String(format: "%.1f", ingredient.carbs), unit: "g", color: .green)
      macroCard("Fat", value: String(format: "%.1f", ingredient.fat), unit: "g", color: .red)
    }
  }

  private func macroCard(_ title: String, value: String, unit: String, color: Color) -> some View {
    FLCard {
      VStack(spacing: AppTheme.Space.xs) {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)
        Text(value)
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
        Text(unit)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
        Text(title)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var secondaryNutrients: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Secondary Nutrition", icon: "chart.bar.doc.horizontal")
        HStack(spacing: AppTheme.Space.md) {
          metric(label: "Fiber", value: String(format: "%.1fg", ingredient.fiber))
          metric(label: "Sugar", value: String(format: "%.1fg", ingredient.sugar))
          metric(label: "Sodium", value: "\(Int((ingredient.sodium * 1000).rounded()))mg")
          Spacer()
        }
      }
    }
  }

  private func metric(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text(value)
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
      Text(label)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private var contextSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("How to Use", icon: "text.book.closed")

        if let typicalUnit = ingredient.typicalUnit, !typicalUnit.isEmpty {
          detailRow(label: "Typical Unit", value: typicalUnit)
        }
        if let storageTip = ingredient.storageTip, !storageTip.isEmpty {
          detailRow(label: "Storage Tip", value: storageTip)
        }
        if let pairsWith = ingredient.pairsWith, !pairsWith.isEmpty {
          detailRow(label: "Pairs Well With", value: pairsWith)
        }
        if let notes = ingredient.notes, !notes.isEmpty {
          detailRow(label: "Notes", value: notes)
        }
      }
    }
  }

  private var aliasSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Also Known As", subtitle: "Search supports these terms", icon: "magnifyingglass")
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(aliases, id: \.self) { alias in
            Text(alias)
              .font(AppTheme.Typography.label)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.xs)
              .background(AppTheme.accent.opacity(0.16), in: Capsule())
          }
        }
      }
    }
  }

  private func detailRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text(label)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
      Text(value)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
    }
  }

  private func loadAliases() {
    guard let id = ingredient.id else { return }
    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
      aliases = (try? deps.ingredientRepository.aliases(for: id)) ?? []
    }
  }

  private func spriteSymbolName() -> String {
    let explicit = ingredient.spriteKey?.lowercased() ?? ""
    switch explicit {
    case "celery": return "leaf"
    case "lettuce": return "leaf.fill"
    case "carrot": return "carrot.fill"
    case "broccoli": return "tree.fill"
    case "tomato": return "circle.fill"
    case "cucumber", "zucchini": return "capsule.portrait.fill"
    case "onion", "green_onion": return "circle.grid.cross.fill"
    default: break
    }

    let group = ingredient.spriteGroup?.lowercased() ?? ""
    switch group {
    case "protein": return "fork.knife"
    case "vegetable": return "leaf"
    case "fruit": return "leaf.circle"
    case "grain_legume": return "takeoutbag.and.cup.and.straw.fill"
    case "dairy_egg": return "drop.fill"
    case "oil_fat": return "drop.triangle.fill"
    case "herb_spice": return "sparkles"
    case "nut_seed": return "smallcircle.filled.circle"
    case "condiment": return "line.3.horizontal.decrease.circle"
    default:
      return "square.grid.2x2"
    }
  }
}
