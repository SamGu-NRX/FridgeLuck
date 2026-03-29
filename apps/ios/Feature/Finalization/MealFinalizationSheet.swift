import SwiftUI

struct MealFinalizationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var vm: MealFinalizationViewModel
  @State private var appeared = false

  let onComplete: () -> Void

  init(
    recipe: Recipe,
    defaultServings: Int = 1,
    deps: AppDependencies,
    onComplete: @escaping () -> Void
  ) {
    _vm = State(
      wrappedValue: MealFinalizationViewModel(
        recipe: recipe,
        defaultServings: defaultServings,
        personalizationService: deps.personalizationService,
        inventoryRepository: deps.inventoryRepository
      ))
    self.onComplete = onComplete
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          heroSection
            .padding(.bottom, AppTheme.Space.sectionBreak)

          portionSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          leftoverSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          ratingSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          makeAgainSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.sectionBreak)

          actionBar
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.bottomClearance)
        }
        .padding(.top, AppTheme.Space.md)
      }
      .flPageBackground()
      .navigationTitle("Log Meal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Skip") {
            dismiss()
          }
        }
      }
      .opacity(appeared ? 1 : 0)
      .onAppear {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.tabEntrance) {
            appeared = true
          }
        }
      }
      .onChange(of: vm.didSave) { _, saved in
        if saved {
          onComplete()
          dismiss()
        }
      }
    }
  }

  // MARK: - Hero

  private var heroSection: some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        LinearGradient(
          colors: [AppTheme.heroLight, AppTheme.heroMid],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .frame(height: 160)

        VStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(.white)
          Text("Meal Complete")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.8))
            .textCase(.uppercase)
            .kerning(1.0)
        }
      }
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: AppTheme.Radius.xl,
          bottomTrailingRadius: AppTheme.Radius.xl,
          topTrailingRadius: 0
        )
      )

      Text(vm.recipe.title)
        .font(AppTheme.Typography.displaySmall)
        .foregroundStyle(AppTheme.textPrimary)
        .padding(.horizontal, AppTheme.Space.page)
    }
  }

  // MARK: - Portions

  private var portionSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("How much did you eat?")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)

      FLServingStepper(servings: $vm.servings, label: "Servings eaten")
    }
  }

  // MARK: - Leftovers

  private var leftoverSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Toggle(isOn: $vm.savedLeftovers) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Saved leftovers?")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
          Text("We\u{2019}ll track them in your fridge")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .tint(AppTheme.accent)

      if vm.savedLeftovers {
        FLServingStepper(
          servings: $vm.leftoverServings,
          label: "Leftover portions"
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(reduceMotion ? nil : AppMotion.gentle, value: vm.savedLeftovers)
  }

  // MARK: - Rating

  private var ratingSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("How was it?")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)

      FLStarRating(rating: $vm.rating)
    }
  }

  // MARK: - Make Again

  private var makeAgainSection: some View {
    Toggle(isOn: $vm.wouldMakeAgain) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text("Would you make this again?")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Helps improve your recommendations")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .tint(AppTheme.accent)
  }

  // MARK: - Action Bar

  private var actionBar: some View {
    VStack(spacing: AppTheme.Space.sm) {
      if let error = vm.errorMessage {
        Text(error)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.dustyRose)
      }

      FLPrimaryButton(
        vm.isSaving ? "Saving..." : "Done",
        systemImage: "checkmark",
        isEnabled: !vm.isSaving
      ) {
        Task { await vm.save() }
      }
    }
  }
}
