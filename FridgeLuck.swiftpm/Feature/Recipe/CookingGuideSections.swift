import SwiftUI

struct CookingGuideTopBar: View {
  let recipeTitle: String
  let counterText: String
  let progress: Double
  let contentHorizontalPadding: CGFloat
  let reduceMotion: Bool
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(width: 32, height: 32)
            .background(AppTheme.surfaceMuted, in: Circle())
        }

        Spacer()

        Text(recipeTitle)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(1)

        Spacer()

        Text(counterText)
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.accent)
          .contentTransition(.numericText())
      }
      .padding(.horizontal, contentHorizontalPadding)

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(AppTheme.surfaceMuted)
          Capsule()
            .fill(AppTheme.accent)
            .frame(width: geo.size.width * progress)
            .animation(reduceMotion ? nil : AppMotion.standard, value: progress)
        }
      }
      .frame(height: 4)
      .padding(.horizontal, contentHorizontalPadding)
    }
    .padding(.top, AppTheme.Space.sm)
    .padding(.bottom, AppTheme.Space.md)
  }
}

struct CookingGuideIngredientsPage: View {
  let ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
  @Binding var checkedIngredients: Set<Int64>
  @Binding var activeSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)]
  let hasSubstitution: (Int64) -> Bool
  let onRequestSubstitution: (Ingredient, RecipeIngredient) -> Void
  let pageAppeared: Bool
  let reduceMotion: Bool
  let contentHorizontalPadding: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Text("Ingredients")
          .font(AppTheme.Typography.displayMedium)
          .foregroundStyle(AppTheme.textPrimary)

        Text("Make sure you have everything before you start")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .opacity(pageAppeared ? 1 : 0)
      .offset(y: pageAppeared ? 0 : 10)

      let required = ingredients.filter { $0.quantity.isRequired }
      let optional = ingredients.filter { !$0.quantity.isRequired }

      if !required.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("REQUIRED")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          ForEach(Array(required.enumerated()), id: \.element.ingredient.id) { index, item in
            ingredientCheckRow(item.ingredient, quantity: item.quantity)
              .opacity(pageAppeared ? 1 : 0)
              .offset(y: pageAppeared ? 0 : 8)
              .animation(
                reduceMotion ? nil : AppMotion.sectionReveal.delay(Double(index) * 0.03),
                value: pageAppeared
              )
          }
        }
      }

      if !optional.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("OPTIONAL")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          ForEach(optional, id: \.ingredient.id) { item in
            ingredientCheckRow(item.ingredient, quantity: item.quantity)
          }
        }
      }
    }
    .padding(.horizontal, contentHorizontalPadding)
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, AppTheme.Space.xxl)
  }

  private func ingredientCheckRow(_ ingredient: Ingredient, quantity: RecipeIngredient) -> some View {
    let ingredientID = ingredient.id ?? -1
    let isChecked = checkedIngredients.contains(ingredientID)
    let hasSwap = hasSubstitution(ingredientID)
    let activeSub = activeSubstitutions[ingredientID]

    return HStack(spacing: AppTheme.Space.sm) {
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          CookingGuideStateTransitions.toggleIngredient(
            ingredientID,
            checkedIngredients: &checkedIngredients
          )
        }
      } label: {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isChecked ? AppTheme.positive : AppTheme.textSecondary)
            .font(.system(size: 20))

          if let activeSub {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text(activeSub.ingredient.displayName)
                .font(AppTheme.Typography.bodyLarge)
                .foregroundStyle(isChecked ? AppTheme.textSecondary : AppTheme.sage)
                .strikethrough(isChecked, color: AppTheme.textSecondary)
              Text("replaces \(ingredient.displayName)")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          } else {
            Text(ingredient.displayName)
              .font(AppTheme.Typography.bodyLarge)
              .foregroundStyle(isChecked ? AppTheme.textSecondary : AppTheme.textPrimary)
              .strikethrough(isChecked, color: AppTheme.textSecondary)
          }

          Spacer()

          Text(quantity.displayQuantity)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .buttonStyle(.plain)

      if hasSwap {
        Button {
          onRequestSubstitution(ingredient, quantity)
        } label: {
          Image(systemName: "arrow.triangle.swap")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(activeSub != nil ? AppTheme.sage : AppTheme.accent)
            .frame(width: 28, height: 28)
            .background(
              activeSub != nil ? AppTheme.sage.opacity(0.12) : AppTheme.accentMuted,
              in: Circle()
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      isChecked
        ? AppTheme.positive.opacity(0.06)
        : (activeSub != nil ? AppTheme.sage.opacity(0.04) : AppTheme.surface),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(
          isChecked
            ? AppTheme.positive.opacity(0.2)
            : (activeSub != nil ? AppTheme.sage.opacity(0.18) : AppTheme.oat.opacity(0.25)),
          lineWidth: 1
        )
    )
  }
}

struct CookingGuideStepPage: View {
  let index: Int
  let totalSteps: Int
  let step: String
  @Binding var completedSteps: Set<Int>
  let pageAppeared: Bool
  let reduceMotion: Bool
  let contentHorizontalPadding: CGFloat

  var body: some View {
    let isCompleted = completedSteps.contains(index)

    return VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
      HStack(alignment: .firstTextBaseline) {
        Text(String(format: "%02d", index + 1))
          .font(.system(size: 72, weight: .bold, design: .serif))
          .foregroundStyle(AppTheme.accent.opacity(0.18))

        Text("of \(totalSteps)")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.bottom, AppTheme.Space.sm)
      }
      .opacity(pageAppeared ? 1 : 0)
      .scaleEffect(pageAppeared ? 1 : 0.85, anchor: .leading)
      .animation(reduceMotion ? nil : AppMotion.heroAppear, value: pageAppeared)

      Text(step)
        .font(.system(.title3, weight: .regular))
        .foregroundStyle(AppTheme.textPrimary)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pageAppeared ? 1 : 0)
        .offset(y: pageAppeared ? 0 : 12)
        .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.08), value: pageAppeared)

      Button {
        withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
          CookingGuideStateTransitions.toggleCompletedStep(
            index,
            completedSteps: &completedSteps
          )
        }
      } label: {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isCompleted ? AppTheme.positive : AppTheme.textSecondary)

          Text(isCompleted ? "Done" : "Mark as done")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(isCompleted ? AppTheme.positive : AppTheme.textSecondary)
        }
        .padding(AppTheme.Space.md)
        .background(
          isCompleted ? AppTheme.positive.opacity(0.08) : AppTheme.surfaceMuted.opacity(0.5),
          in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .opacity(pageAppeared ? 1 : 0)
      .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.14), value: pageAppeared)

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, contentHorizontalPadding)
    .padding(.top, AppTheme.Space.lg)
    .padding(.bottom, AppTheme.Space.xxl)
  }
}

struct CookingGuideBottomNavigation: View {
  let currentPage: Int
  let isOnLastStep: Bool
  let contentHorizontalPadding: CGFloat
  let onBack: () -> Void
  let onNext: () -> Void
  let onComplete: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      FLWaveDivider()
        .padding(.horizontal, contentHorizontalPadding)

      HStack(spacing: AppTheme.Space.md) {
        if currentPage > 0 {
          FLSecondaryButton("Back", systemImage: "chevron.left") {
            onBack()
          }
        }

        if isOnLastStep {
          FLPrimaryButton("I Made This!", systemImage: "frying.pan.fill") {
            onComplete()
          }
        } else {
          FLPrimaryButton("Next", systemImage: "chevron.right") {
            onNext()
          }
        }
      }
      .padding(.horizontal, contentHorizontalPadding)
      .padding(.vertical, AppTheme.Space.md)
    }
    .background(AppTheme.bg)
  }
}
