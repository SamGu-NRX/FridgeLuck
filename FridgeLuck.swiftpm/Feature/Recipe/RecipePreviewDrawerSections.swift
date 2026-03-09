import SwiftUI
import UIKit

struct RecipePreviewHeroSection: View {
  let recipe: Recipe
  let existingPhoto: UIImage?

  var body: some View {
    ZStack {
      heroGradient
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 0))

      if let photo = existingPhoto {
        Image(uiImage: photo)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(height: 240)
          .clipped()
          .overlay {
            LinearGradient(
              colors: [.clear, AppTheme.bg.opacity(0.7)],
              startPoint: .center,
              endPoint: .bottom
            )
          }
      } else {
        VStack(spacing: AppTheme.Space.sm) {
          ZStack {
            FLOrganicBlob(seed: recipe.title.hashValue)
              .fill(AppTheme.surface.opacity(0.15))
              .frame(width: 100, height: 100)

            Image(systemName: "camera.fill")
              .font(.system(size: 28))
              .foregroundStyle(.white.opacity(0.7))
          }

          Text("Photo added after cooking")
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }

  private var heroGradient: some View {
    let tags = recipe.recipeTags

    let (primary, secondary): (Color, Color) = {
      if tags.contains(.asian) { return (AppTheme.sage, AppTheme.deepOliveLight) }
      if tags.contains(.mediterranean) { return (AppTheme.oat, AppTheme.accent.opacity(0.7)) }
      if tags.contains(.mexican) { return (AppTheme.accent, AppTheme.accentLight) }
      if tags.contains(.breakfast) { return (AppTheme.heroLight, AppTheme.oat) }
      if tags.contains(.comfort) { return (AppTheme.dustyRose, AppTheme.accentLight) }
      if tags.contains(.vegetarian) || tags.contains(.vegan) {
        return (AppTheme.sage, AppTheme.sageLight)
      }
      return (AppTheme.bgDeep, AppTheme.oat.opacity(0.6))
    }()

    return LinearGradient(
      colors: [primary, secondary],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

struct RecipePreviewTitleSection: View {
  let recipe: Recipe

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text(recipe.title)
            .font(AppTheme.Typography.displayMedium)
            .foregroundStyle(AppTheme.textPrimary)

          HStack(spacing: AppTheme.Space.md) {
            Label("\(recipe.timeMinutes) min", systemImage: "clock")
            Label(
              "\(recipe.servings) serving\(recipe.servings > 1 ? "s" : "")",
              systemImage: "person.2"
            )
          }
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        if recipe.source == .aiGenerated {
          FLStatusPill(text: "AI", kind: .neutral)
        }
      }

      if !recipe.recipeTags.labels.isEmpty {
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(recipe.recipeTags.labels, id: \.self) { tag in
            Text(tag.replacingOccurrences(of: "_", with: " "))
              .font(AppTheme.Typography.labelSmall)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.chipVertical)
              .background(AppTheme.surfaceMuted, in: Capsule())
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
    }
  }
}

struct RecipePreviewHealthSection: View {
  let scoredRecipe: ScoredRecipe

  var body: some View {
    HStack(spacing: AppTheme.Space.md) {
      HStack(spacing: AppTheme.Space.xxs) {
        ForEach(1...5, id: \.self) { star in
          Image(systemName: star <= scoredRecipe.healthScore.rating ? "star.fill" : "star")
            .font(.system(size: 14))
            .foregroundStyle(
              star <= scoredRecipe.healthScore.rating
                ? AppTheme.accent : AppTheme.oat.opacity(0.4))
        }
      }

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(scoredRecipe.healthScore.label)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textPrimary)
        Text(scoredRecipe.healthScore.reasoning)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.sage.opacity(0.06),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.sage.opacity(0.15), lineWidth: 1)
    )
  }
}

struct RecipePreviewMacroSection: View {
  let macros: RecipeMacros

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Nutrition", subtitle: "Per serving", icon: "chart.bar")

        HStack(spacing: AppTheme.Space.sm) {
          macroCell(
            "Calories",
            value: "\(Int(macros.caloriesPerServing.rounded()))",
            unit: "kcal",
            color: AppTheme.accent
          )
          macroCell(
            "Protein",
            value: "\(Int(macros.proteinPerServing.rounded()))",
            unit: "g",
            color: AppTheme.sage
          )
          macroCell(
            "Carbs",
            value: "\(Int(macros.carbsPerServing.rounded()))",
            unit: "g",
            color: AppTheme.oat
          )
          macroCell(
            "Fat",
            value: "\(Int(macros.fatPerServing.rounded()))",
            unit: "g",
            color: AppTheme.accentLight
          )
        }

        macroSplitBar

        HStack(spacing: AppTheme.Space.md) {
          secondaryNutrient(label: "Fiber", value: "\(Int(macros.fiberPerServing.rounded()))g")
          secondaryNutrient(label: "Sugar", value: "\(Int(macros.sugarPerServing.rounded()))g")
          secondaryNutrient(label: "Sodium", value: "\(Int(macros.sodiumPerServing.rounded()))mg")
          Spacer()
        }
      }
    }
  }

  private func macroCell(_ label: String, value: String, unit: String, color: Color) -> some View {
    VStack(spacing: AppTheme.Space.xxs) {
      Text(value)
        .font(AppTheme.Typography.dataMedium)
        .foregroundStyle(color)
        .contentTransition(.numericText())
      Text(unit)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      Text(label)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var macroSplitBar: some View {
    let split = macros.macroSplit
    return GeometryReader { geo in
      HStack(spacing: AppTheme.Space.xxxs) {
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.sage)
          .frame(width: max(2, geo.size.width * split.proteinPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.oat)
          .frame(width: max(2, geo.size.width * split.carbsPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.accentLight)
          .frame(width: max(2, geo.size.width * split.fatPct))
      }
    }
    .frame(height: 8)
    .clipShape(Capsule())
  }

  private func secondaryNutrient(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      Text(value)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textPrimary)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }
}

struct RecipePreviewIngredientSection: View {
  let ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
  let activeSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)]
  let hasSubstitutions: (Int64) -> Bool
  let onIngredientSelected: (Ingredient) -> Void
  let onSwapSelected: (Ingredient, RecipeIngredient) -> Void

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Ingredients",
          subtitle: "\(ingredients.count) items",
          icon: "carrot.fill"
        )

        let required = ingredients.filter { $0.quantity.isRequired }
        let optional = ingredients.filter { !$0.quantity.isRequired }
        let firstSwapIngredientID = ingredients.first {
          hasSubstitutions($0.ingredient.id ?? -1)
        }?.ingredient.id

        if !required.isEmpty {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            ForEach(required, id: \.ingredient.id) { item in
              ingredientRow(
                item.ingredient,
                quantity: item.quantity,
                isRequired: true,
                isSwapSpotlightTarget: item.ingredient.id == firstSwapIngredientID
              )
            }
          }
        }

        if !optional.isEmpty {
          Text("Optional")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.top, AppTheme.Space.xs)

          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            ForEach(optional, id: \.ingredient.id) { item in
              ingredientRow(
                item.ingredient,
                quantity: item.quantity,
                isRequired: false,
                isSwapSpotlightTarget: item.ingredient.id == firstSwapIngredientID
              )
            }
          }
        }
      }
    }
  }

  private func ingredientRow(
    _ ingredient: Ingredient,
    quantity: RecipeIngredient,
    isRequired: Bool,
    isSwapSpotlightTarget: Bool = false
  ) -> some View {
    let ingredientID = ingredient.id ?? -1
    let hasSwap = hasSubstitutions(ingredientID)
    let activeSub = activeSubstitutions[ingredientID]

    return HStack(spacing: AppTheme.Space.sm) {
      Button {
        onIngredientSelected(activeSub?.ingredient ?? ingredient)
      } label: {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isRequired ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(isRequired ? AppTheme.positive : AppTheme.textSecondary)
            .font(AppTheme.Typography.label)
            .animation(.default, value: isRequired)

          if let sub = activeSub {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text(sub.ingredient.displayName)
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.sage)
              Text("replaces \(ingredient.displayName)")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          } else {
            Text(ingredient.displayName)
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textPrimary)
          }

          Spacer()

          Text(quantity.displayQuantity)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .buttonStyle(.plain)

      if hasSwap {
        if isSwapSpotlightTarget {
          swapActionButton(activeSub: activeSub) {
            onSwapSelected(ingredient, quantity)
          }
          .id("swapButton")
          .spotlightAnchor("swapButton")
        } else {
          swapActionButton(activeSub: activeSub) {
            onSwapSelected(ingredient, quantity)
          }
        }
      }
    }
    .padding(.horizontal, AppTheme.Space.xs)
    .padding(.vertical, AppTheme.Space.xs)
    .background(
      activeSub != nil ? AppTheme.sage.opacity(0.05) : AppTheme.surfaceMuted.opacity(0.4),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
        .stroke(activeSub != nil ? AppTheme.sage.opacity(0.2) : Color.clear, lineWidth: 1)
    )
  }

  private func swapActionButton(
    activeSub: (substitution: Substitution, ingredient: Ingredient)?,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: "arrow.triangle.swap")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(activeSub != nil ? AppTheme.sage : AppTheme.accent)
        .frame(width: 30, height: 30)
        .background(
          activeSub != nil ? AppTheme.sage.opacity(0.12) : AppTheme.accentMuted,
          in: Circle()
        )
        .animation(.default, value: activeSub != nil)
    }
    .buttonStyle(.plain)
  }
}

struct RecipePreviewBottomCTA: View {
  let onStartCooking: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(AppTheme.oat.opacity(0.30))
        .frame(height: 1)

      VStack(spacing: AppTheme.Space.xs) {
        FLPrimaryButton("Start Cooking", systemImage: "flame.fill") {
          onStartCooking()
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.md)
      .background(AppTheme.bg)
    }
  }
}
