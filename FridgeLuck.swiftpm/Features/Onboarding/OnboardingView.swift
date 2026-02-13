import SwiftUI

/// Health onboarding and profile editor.
struct OnboardingView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isRequired: Bool
  let onComplete: () -> Void

  @State private var goal: HealthGoal = .general
  @State private var dailyCalories: Int = HealthGoal.general.suggestedCalories
  @State private var selectedRestrictions: Set<String> = []
  @State private var selectedAllergens: Set<Int64> = []
  @State private var allIngredients: [Ingredient] = []

  @State private var stepIndex = 0
  @State private var stepDirection: StepDirection = .forward
  @State private var isLoaded = false
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showAllergenPicker = false

  private let restrictionOptions: [(id: String, title: String, icon: String)] = [
    ("vegetarian", "Vegetarian", "leaf"),
    ("vegan", "Vegan", "leaf.circle"),
    ("gluten_free", "Gluten Free", "takeoutbag.and.cup.and.straw"),
    ("dairy_free", "Dairy Free", "drop"),
    ("low_carb", "Low Carb", "bolt"),
  ]

  private enum Step: Int, CaseIterable {
    case goals
    case restrictions
    case allergens

    var title: String {
      switch self {
      case .goals:
        return "Set Your Goal"
      case .restrictions:
        return "Diet Preferences"
      case .allergens:
        return "Allergen Safety"
      }
    }

    var subtitle: String {
      switch self {
      case .goals:
        return "Personalize calories and nutrition direction."
      case .restrictions:
        return "Filter recipes to match how you like to eat."
      case .allergens:
        return "Prioritize common allergens first, then refine."
      }
    }

    var icon: String {
      switch self {
      case .goals:
        return "target"
      case .restrictions:
        return "slider.horizontal.3"
      case .allergens:
        return "exclamationmark.shield"
      }
    }
  }

  private enum StepDirection {
    case forward
    case backward
  }

  private enum Layout {
    static let headerMinHeight: CGFloat = 156
    static let actionButtonHeight: CGFloat = 56
    static let allergenGroupChipHeight: CGFloat = 92
  }

  private var currentStep: Step {
    Step(rawValue: stepIndex) ?? .goals
  }

  private var totalSteps: Int {
    Step.allCases.count
  }

  private var selectedAllergenIngredients: [Ingredient] {
    allIngredients
      .filter { ingredient in
        guard let id = ingredient.id else { return false }
        return selectedAllergens.contains(id)
      }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        header

        stepContentContainer
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        footer
      }
      .flPageBackground()
      .navigationTitle(isRequired ? "Onboarding" : "Health Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if !isRequired {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
      }
      .alert(
        "Unable to Save",
        isPresented: Binding(
          get: { errorMessage != nil },
          set: { show in
            if !show { errorMessage = nil }
          }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
      .sheet(isPresented: $showAllergenPicker) {
        AllergenPickerView(
          ingredients: allIngredients,
          selectedIDs: $selectedAllergens
        )
      }
      .task {
        guard !isLoaded else { return }
        isLoaded = true
        await loadProfile()
      }
      .onChange(of: goal) { oldGoal, newGoal in
        if dailyCalories == oldGoal.suggestedCalories {
          dailyCalories = newGoal.suggestedCalories
        }
      }
    }
  }

  private var stepContentContainer: some View {
    ZStack {
      if currentStep == .goals {
        goalStep
          .transition(stepTransition)
      }
      if currentStep == .restrictions {
        restrictionStep
          .transition(stepTransition)
      }
      if currentStep == .allergens {
        allergenStep
          .transition(stepTransition)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .clipped()
  }

  private var stepTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    switch stepDirection {
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

  private var header: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .center) {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: currentStep.icon)
            .foregroundStyle(AppTheme.accent)
          Text("Step \(stepIndex + 1) of \(totalSteps)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        if isRequired {
          FLStatusPill(text: "New", kind: .warning)
        }
      }

      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(currentStep.title)
          .font(.title2.bold())
          .foregroundStyle(AppTheme.textPrimary)
        Text(currentStep.subtitle)
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
      }

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(AppTheme.textSecondary.opacity(0.15))
          Capsule()
            .fill(AppTheme.accent)
            .frame(width: geo.size.width * (Double(stepIndex + 1) / Double(totalSteps)))
        }
      }
      .frame(height: 8)
      .animation(reduceMotion ? nil : AppMotion.onboardingStep, value: stepIndex)
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, AppTheme.Space.sm)
    .frame(maxWidth: .infinity, minHeight: Layout.headerMinHeight, alignment: .topLeading)
  }

  private var goalStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        FLCard(tone: .warm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Pick your primary nutrition direction")
              .font(.headline)
              .foregroundStyle(AppTheme.textPrimary)
            Text("You can update this anytime from profile settings.")
              .font(.subheadline)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppTheme.Space.sm
        ) {
          goalCard(.general, accent: .yellow)
          goalCard(.weightLoss, accent: .green)
          goalCard(.muscleGain, accent: .blue)
          goalCard(.maintenance, accent: .orange)
        }

        FLCard {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader(
              "Daily Calories", subtitle: "Tune your default target", icon: "flame.fill")

            HStack(spacing: AppTheme.Space.sm) {
              Button {
                dailyCalories = max(1000, dailyCalories - 50)
              } label: {
                Image(systemName: "minus")
                  .font(.headline)
                  .frame(width: 40, height: 40)
                  .background(AppTheme.surfaceMuted, in: Circle())
              }
              .buttonStyle(.plain)

              Text("\(dailyCalories)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)

              Button {
                dailyCalories = min(4500, dailyCalories + 50)
              } label: {
                Image(systemName: "plus")
                  .font(.headline)
                  .frame(width: 40, height: 40)
                  .background(AppTheme.surfaceMuted, in: Circle())
              }
              .buttonStyle(.plain)
            }

            Slider(
              value: Binding(
                get: { Double(dailyCalories) },
                set: { dailyCalories = Int($0.rounded()) }
              ),
              in: 1000...4500,
              step: 50
            )
            .tint(AppTheme.accent)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func goalCard(_ value: HealthGoal, accent: Color) -> some View {
    let selected = goal == value

    return Button {
      goal = value
    } label: {
      FLCard(tone: selected ? .warm : .normal) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Circle()
            .fill(selected ? accent : AppTheme.textSecondary.opacity(0.2))
            .frame(width: 10, height: 10)
          Text(value.displayName)
            .font(.subheadline.bold())
            .foregroundStyle(AppTheme.textPrimary)
          Text("\(value.suggestedCalories) kcal")
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
    .buttonStyle(.plain)
  }

  private var restrictionStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        FLCard(tone: .warm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Choose your dietary constraints")
              .font(.headline)
              .foregroundStyle(AppTheme.textPrimary)
            Text("This helps filter out recipes that don’t fit your preferences.")
              .font(.subheadline)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        FLCard {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: AppTheme.Space.xs)],
            spacing: AppTheme.Space.xs
          ) {
            ForEach(restrictionOptions, id: \.id) { option in
              let selected = selectedRestrictions.contains(option.id)

              Button {
                toggleRestriction(option.id)
              } label: {
                HStack(spacing: AppTheme.Space.xs) {
                  Image(systemName: option.icon)
                  Text(option.title)
                    .font(.caption.weight(.semibold))
                  Spacer(minLength: 0)
                  Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                }
                .foregroundStyle(selected ? AppTheme.textPrimary : AppTheme.textSecondary)
                .padding(.horizontal, AppTheme.Space.sm)
                .padding(.vertical, AppTheme.Space.sm)
                .background(
                  selected ? AppTheme.accent.opacity(0.3) : AppTheme.surface,
                  in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .stroke(
                      selected ? AppTheme.accent : AppTheme.textSecondary.opacity(0.15),
                      lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }

        if !selectedRestrictions.isEmpty {
          FLCard {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
              FLSectionHeader("Active Filters", icon: "line.3.horizontal.decrease.circle")
              Text(
                selectedRestrictions.sorted().joined(separator: ", ").replacingOccurrences(
                  of: "_", with: " "
                ).capitalized
              )
              .font(.subheadline)
              .foregroundStyle(AppTheme.textSecondary)
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private var allergenStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        FLCard(tone: .warning) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Start with common allergens")
              .font(.headline)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Tap any group below to add/remove matching ingredients in one action.")
              .font(.subheadline)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        FLCard {
          LazyVGrid(
            columns: [
              GridItem(.flexible(), spacing: AppTheme.Space.xs),
              GridItem(.flexible(), spacing: AppTheme.Space.xs),
            ],
            spacing: AppTheme.Space.xs
          ) {
            ForEach(AllergenSupport.groups) { group in
              allergenGroupChip(group)
            }
          }
        }

        FLSecondaryButton("Open Full Allergen Picker", systemImage: "magnifyingglass") {
          showAllergenPicker = true
        }

        FLCard {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader(
              "Selected Allergen Ingredients",
              subtitle: "\(selectedAllergens.count) selected",
              icon: "checkmark.shield.fill"
            )

            if selectedAllergenIngredients.isEmpty {
              Text("No allergens selected yet.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            } else {
              FlowLayout(spacing: AppTheme.Space.xs) {
                ForEach(Array(selectedAllergenIngredients.prefix(40)), id: \.id) { ingredient in
                  Text(ingredient.displayName)
                    .font(.caption)
                    .padding(.horizontal, AppTheme.Space.sm)
                    .padding(.vertical, AppTheme.Space.xs)
                    .background(AppTheme.accent.opacity(0.18), in: Capsule())
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func allergenGroupChip(_ group: AllergenGroupDefinition) -> some View {
    let matchedIDs = AllergenSupport.matchingIDs(for: group, in: allIngredients)
    let selectedCount = selectedAllergens.intersection(matchedIDs).count
    let isFullySelected = !matchedIDs.isEmpty && selectedCount == matchedIDs.count
    let isPartiallySelected = selectedCount > 0 && !isFullySelected
    let isSelected = isFullySelected || isPartiallySelected

    return Button {
      toggleAllergenGroup(group)
    } label: {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: group.systemImage)
        VStack(alignment: .leading, spacing: 2) {
          Text(group.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(AppTheme.textPrimary)
          Text(isSelected ? "\(selectedCount) selected" : group.subtitle)
            .font(.caption2)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 34, alignment: .topLeading)
        Spacer(minLength: 0)
        Image(
          systemName: isFullySelected
            ? "checkmark.circle.fill" : (isPartiallySelected ? "minus.circle.fill" : "circle"))
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.sm)
      .frame(
        maxWidth: .infinity, minHeight: Layout.allergenGroupChipHeight,
        maxHeight: Layout.allergenGroupChipHeight, alignment: .leading
      )
      .background(
        isSelected ? AppTheme.accent.opacity(0.3) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(isSelected ? AppTheme.accent : AppTheme.textSecondary.opacity(0.15), lineWidth: 1)
      )
      .opacity(matchedIDs.isEmpty ? 0.75 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(matchedIDs.isEmpty)
  }

  private var footer: some View {
    let backVisible = stepIndex > 0

    return VStack(spacing: AppTheme.Space.xs) {
      HStack(spacing: backVisible ? AppTheme.Space.sm : 0) {
        FLSecondaryButton("Back", systemImage: "chevron.left") {
          setStep(max(0, stepIndex - 1), direction: .backward)
        }
        .frame(width: backVisible ? 132 : 0, height: Layout.actionButtonHeight)
        .opacity(backVisible ? 1 : 0)
        .clipped()
        .allowsHitTesting(backVisible)

        FLPrimaryButton(
          primaryButtonTitle,
          systemImage: primaryButtonIcon,
          isEnabled: !isSaving,
          labelAnimation: .subtleBlend
        ) {
          handlePrimaryAction()
        }
      }
      .animation(reduceMotion ? nil : AppMotion.onboardingStep, value: backVisible)
      .frame(minHeight: Layout.actionButtonHeight)

      if isSaving {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
    .background(AppTheme.bg)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(AppTheme.textSecondary.opacity(0.14))
        .frame(height: 1)
    }
  }

  private var primaryButtonTitle: String {
    if stepIndex == totalSteps - 1 {
      return isRequired ? "Finish Setup" : "Save Profile"
    }
    return "Continue"
  }

  private var primaryButtonIcon: String {
    if stepIndex == totalSteps - 1 {
      return "checkmark.circle.fill"
    }
    return "arrow.right"
  }

  private func handlePrimaryAction() {
    if stepIndex < totalSteps - 1 {
      setStep(stepIndex + 1, direction: .forward)
      return
    }

    saveProfile()
  }

  private func toggleRestriction(_ id: String) {
    if selectedRestrictions.contains(id) {
      selectedRestrictions.remove(id)
    } else {
      selectedRestrictions.insert(id)
    }
  }

  private func toggleAllergenGroup(_ group: AllergenGroupDefinition) {
    let ids = AllergenSupport.matchingIDs(for: group, in: allIngredients)
    guard !ids.isEmpty else { return }

    let selectedCount = selectedAllergens.intersection(ids).count
    if selectedCount == ids.count {
      selectedAllergens.subtract(ids)
    } else {
      selectedAllergens.formUnion(ids)
    }
  }

  private func setStep(_ newValue: Int, direction: StepDirection) {
    let clamped = min(max(newValue, 0), totalSteps - 1)
    guard clamped != stepIndex else { return }
    stepDirection = direction

    if reduceMotion {
      stepIndex = clamped
    } else {
      withAnimation(AppMotion.onboardingStep) {
        stepIndex = clamped
      }
    }
  }

  private func loadProfile() async {
    allIngredients = (try? deps.ingredientRepository.fetchAll()) ?? []

    do {
      guard try deps.userDataRepository.hasCompletedOnboarding() else {
        dailyCalories = goal.suggestedCalories
        return
      }

      let profile = try deps.userDataRepository.fetchHealthProfile()
      goal = profile.goal
      dailyCalories = profile.dailyCalories ?? profile.goal.suggestedCalories
      selectedRestrictions = Set(profile.parsedDietaryRestrictions)
      selectedAllergens = Set(profile.parsedAllergenIds)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveProfile() {
    isSaving = true
    defer { isSaving = false }

    do {
      let restrictionsJSON = try encodeJSON(Array(selectedRestrictions).sorted())
      let allergensJSON = try encodeJSON(Array(selectedAllergens).sorted())
      let split = goal.defaultMacroSplit

      let profile = HealthProfile(
        goal: goal,
        dailyCalories: dailyCalories,
        proteinPct: split.protein,
        carbsPct: split.carbs,
        fatPct: split.fat,
        dietaryRestrictions: restrictionsJSON,
        allergenIngredientIds: allergensJSON
      )
      try deps.userDataRepository.saveHealthProfile(profile)
      onComplete()

      if !isRequired {
        dismiss()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw NSError(
        domain: "OnboardingView", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to serialize profile values."]
      )
    }
    return string
  }
}
