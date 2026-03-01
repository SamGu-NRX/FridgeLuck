import SwiftUI

/// A paginated cooking guide experience. Each cooking step gets its own full page.
/// Page 0 is the ingredients checklist, pages 1-N are individual steps,
/// and the final action triggers the "I Made This" celebration.
struct CookingGuideView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  var onComplete: () -> Void

  @State private var currentPage: Int = 0
  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var checkedIngredients: Set<Int64> = []
  @State private var completedSteps: Set<Int> = []
  @State private var showCelebration = false
  @State private var pageDirection: PageDirection = .forward
  @State private var pageAppeared = false
  @State private var substitutionTarget: (ingredient: Ingredient, quantity: RecipeIngredient)?
  @State private var activeSubstitutions:
    [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:]

  private var recipe: Recipe { scoredRecipe.recipe }

  private var instructionSteps: [String] {
    recipe.instructions
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Total pages: 1 (ingredients) + N (steps)
  private var totalPages: Int { 1 + instructionSteps.count }
  private var totalSteps: Int { instructionSteps.count }
  private var isOnIngredientsPage: Bool { currentPage == 0 }
  private var isOnLastStep: Bool { currentPage == totalPages - 1 }
  private var currentStepIndex: Int { currentPage - 1 }
  private var contentHorizontalPadding: CGFloat { AppTheme.Space.page }

  private var topBarCounterText: String {
    guard totalSteps > 0 else { return "0/0" }
    if isOnIngredientsPage { return "Prep" }
    return "\(currentStepIndex + 1)/\(totalSteps)"
  }

  private var progress: Double {
    guard totalSteps > 0 else { return 0 }
    return min(max(Double(currentPage) / Double(totalSteps), 0), 1)
  }

  var body: some View {
    ZStack {
      // Background
      AppTheme.bg.ignoresSafeArea()

      VStack(spacing: 0) {
        // Top bar: close + progress
        topBar

        // Page content
        pageContent
          .id(currentPage)
          .transition(pageTransition)
          .animation(reduceMotion ? nil : AppMotion.pageTurn, value: currentPage)

        Spacer(minLength: 0)

        // Bottom navigation
        bottomNavigation
      }

      if showCelebration {
        CookingCelebrationView(
          scoredRecipe: scoredRecipe,
          onDismiss: {
            dismiss()
            onComplete()
          }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .zIndex(10)
      }
    }
    .task {
      await loadIngredients()
      if !reduceMotion {
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(AppMotion.sectionReveal) {
          pageAppeared = true
        }
      } else {
        pageAppeared = true
      }
    }
    .sheet(
      item: Binding(
        get: {
          substitutionTarget.map {
            BookSubstitutionTarget(ingredient: $0.ingredient, quantity: $0.quantity)
          }
        },
        set: { wrapper in substitutionTarget = wrapper.map { ($0.ingredient, $0.quantity) } }
      )
    ) { target in
      SubstitutionSheet(
        ingredient: target.ingredient,
        quantityGrams: target.quantity.quantityGrams,
        displayQuantity: target.quantity.displayQuantity
      ) { substitution, subIngredient in
        withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
          activeSubstitutions[target.ingredient.id ?? -1] = (substitution, subIngredient)
        }
      }
    }
  }

  // MARK: - Top Bar

  private var topBar: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(width: 32, height: 32)
            .background(AppTheme.surfaceMuted, in: Circle())
        }

        Spacer()

        Text(recipe.title)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(1)

        Spacer()

        // Page counter
        Text(topBarCounterText)
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.accent)
          .contentTransition(.numericText())
      }
      .padding(.horizontal, contentHorizontalPadding)

      // Progress bar
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

  // MARK: - Page Content

  @ViewBuilder
  private var pageContent: some View {
    ScrollView {
      if isOnIngredientsPage {
        ingredientsPage
      } else {
        stepPage(index: currentStepIndex)
      }
    }
  }

  // MARK: - Ingredients Page

  private var ingredientsPage: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      // Page header
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

      // Ingredient checklist
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

  private func ingredientCheckRow(
    _ ingredient: Ingredient, quantity: RecipeIngredient
  ) -> some View {
    let isChecked = checkedIngredients.contains(ingredient.id ?? -1)
    let hasSwap = deps.substitutionService.hasSubstitutions(for: ingredient.id ?? -1)
    let activeSub = activeSubstitutions[ingredient.id ?? -1]

    return HStack(spacing: AppTheme.Space.sm) {
      // Check toggle + ingredient name
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          if isChecked {
            checkedIngredients.remove(ingredient.id ?? -1)
          } else {
            checkedIngredients.insert(ingredient.id ?? -1)
          }
        }
      } label: {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isChecked ? AppTheme.positive : AppTheme.textSecondary)
            .font(.system(size: 20))

          if let sub = activeSub {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text(sub.ingredient.displayName)
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

      // Swap button
      if hasSwap {
        Button {
          substitutionTarget = (ingredient, quantity)
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

  // MARK: - Step Page

  private func stepPage(index: Int) -> some View {
    let step = instructionSteps[index]
    let isCompleted = completedSteps.contains(index)

    return VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
      // Large step number
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

      // Step instruction
      Text(step)
        .font(.system(.title3, weight: .regular))
        .foregroundStyle(AppTheme.textPrimary)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pageAppeared ? 1 : 0)
        .offset(y: pageAppeared ? 0 : 12)
        .animation(
          reduceMotion ? nil : AppMotion.sectionReveal.delay(0.08),
          value: pageAppeared
        )

      // Done toggle
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
          if isCompleted {
            completedSteps.remove(index)
          } else {
            completedSteps.insert(index)
          }
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
      .animation(
        reduceMotion ? nil : AppMotion.sectionReveal.delay(0.14),
        value: pageAppeared
      )

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, contentHorizontalPadding)
    .padding(.top, AppTheme.Space.lg)
    .padding(.bottom, AppTheme.Space.xxl)
  }

  // MARK: - Bottom Navigation

  private var bottomNavigation: some View {
    VStack(spacing: 0) {
      FLWaveDivider()
        .padding(.horizontal, contentHorizontalPadding)

      HStack(spacing: AppTheme.Space.md) {
        // Back button
        if currentPage > 0 {
          FLSecondaryButton("Back", systemImage: "chevron.left") {
            goToPreviousPage()
          }
        }

        // Next / "I Made This" button
        if isOnLastStep {
          FLPrimaryButton("I Made This!", systemImage: "frying.pan.fill") {
            withAnimation(reduceMotion ? nil : AppMotion.celebration) {
              showCelebration = true
            }
          }
        } else {
          FLPrimaryButton("Next", systemImage: "chevron.right") {
            goToNextPage()
          }
        }
      }
      .padding(.horizontal, contentHorizontalPadding)
      .padding(.vertical, AppTheme.Space.md)
    }
    .background(AppTheme.bg)
  }

  // MARK: - Navigation Actions

  private func goToNextPage() {
    guard currentPage < totalPages - 1 else { return }
    pageDirection = .forward
    pageAppeared = false
    withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
      currentPage += 1
    }
    // Re-trigger page appear animation
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      withAnimation(reduceMotion ? nil : AppMotion.sectionReveal) {
        pageAppeared = true
      }
    }
  }

  private func goToPreviousPage() {
    guard currentPage > 0 else { return }
    pageDirection = .backward
    pageAppeared = false
    withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
      currentPage -= 1
    }
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      withAnimation(reduceMotion ? nil : AppMotion.sectionReveal) {
        pageAppeared = true
      }
    }
  }

  private var pageTransition: AnyTransition {
    switch pageDirection {
    case .forward:
      return .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .backward:
      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  // MARK: - Data Loading

  private func loadIngredients() async {
    guard let recipeId = recipe.id else { return }
    ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeId)) ?? []
  }
}

// MARK: - Page Direction

private enum PageDirection {
  case forward
  case backward
}

// MARK: - Substitution Target Wrapper

private struct BookSubstitutionTarget: Identifiable {
  let ingredient: Ingredient
  let quantity: RecipeIngredient
  var id: Int64 { ingredient.id ?? -1 }
}
