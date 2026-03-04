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
  @State private var ingredientByID: [Int64: Ingredient] = [:]
  @State private var allergenGroupMatchesByID: [String: Set<Int64>] = [:]

  @State private var stepIndex = 0
  @State private var stepDirection: StepDirection = .forward
  @State private var isTransitioning = false
  @State private var isLoaded = false
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showAllergenPicker = false

  private let restrictionOptions: [OnboardingRestrictionOption] = [
    .init(id: "vegetarian", title: "Vegetarian", icon: "leaf"),
    .init(id: "vegan", title: "Vegan", icon: "leaf.circle"),
    .init(id: "gluten_free", title: "Gluten Free", icon: "takeoutbag.and.cup.and.straw"),
    .init(id: "dairy_free", title: "Dairy Free", icon: "drop"),
    .init(id: "low_carb", title: "Low Carb", icon: "bolt"),
  ]

  private enum Step: Int, CaseIterable {
    case goals
    case restrictions
    case allergens

    var title: String {
      switch self {
      case .goals: return "Set Your Goal"
      case .restrictions: return "Diet Preferences"
      case .allergens: return "Allergen Safety"
      }
    }

    var subtitle: String {
      switch self {
      case .goals: return "Personalize calories and nutrition direction."
      case .restrictions: return "Filter recipes to match how you like to eat."
      case .allergens: return "Prioritize common allergens first, then refine."
      }
    }
  }

  private enum StepDirection {
    case forward
    case backward
  }

  private var currentStep: Step {
    Step(rawValue: stepIndex) ?? .goals
  }

  private var totalSteps: Int {
    Step.allCases.count
  }

  private var selectedAllergenIngredients: [Ingredient] {
    selectedAllergens
      .compactMap { ingredientByID[$0] }
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
          set: { show in if !show { errorMessage = nil } }
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
      Group {
        switch currentStep {
        case .goals:
          goalStep
        case .restrictions:
          restrictionStep
        case .allergens:
          allergenStep
        }
      }
      .id(currentStep)
      .transition(stepTransition)
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
    OnboardingStepHeader(
      stepIndex: stepIndex,
      totalSteps: totalSteps,
      title: currentStep.title,
      subtitle: currentStep.subtitle,
      isRequired: isRequired,
      reduceMotion: reduceMotion
    )
  }

  private var goalStep: some View {
    OnboardingGoalStepSection(goal: $goal, dailyCalories: $dailyCalories)
  }

  private var restrictionStep: some View {
    OnboardingRestrictionStepSection(
      options: restrictionOptions,
      selectedRestrictions: selectedRestrictions,
      onToggle: toggleRestriction
    )
  }

  private var allergenStep: some View {
    OnboardingAllergenStepSection(
      allergenGroupMatchesByID: allergenGroupMatchesByID,
      selectedAllergens: selectedAllergens,
      selectedAllergenIngredients: selectedAllergenIngredients,
      onToggleGroup: toggleAllergenGroup,
      onOpenPicker: { showAllergenPicker = true }
    )
  }

  private var footer: some View {
    OnboardingFooter(
      stepIndex: stepIndex,
      totalSteps: totalSteps,
      isSaving: isSaving,
      isTransitioning: isTransitioning,
      reduceMotion: reduceMotion,
      primaryButtonTitle: primaryButtonTitle,
      primaryButtonIcon: primaryButtonIcon,
      onBack: { setStep(max(0, stepIndex - 1), direction: .backward) },
      onPrimaryAction: handlePrimaryAction
    )
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
    guard !isTransitioning, !isSaving else { return }

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
    let ids = allergenGroupMatchesByID[group.id] ?? []
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
    guard !isTransitioning else { return }

    stepDirection = direction
    isTransitioning = true

    if reduceMotion {
      stepIndex = clamped
    } else {
      withAnimation(AppMotion.onboardingStep) {
        stepIndex = clamped
      }
    }

    let lockDurationNanoseconds: UInt64 = reduceMotion ? 10_000_000 : 280_000_000
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: lockDurationNanoseconds)
      isTransitioning = false
    }
  }

  private func loadProfile() async {
    let ingredientRepository = deps.ingredientRepository
    let userDataRepository = deps.userDataRepository

    let fetchedIngredients = await Task.detached(priority: .userInitiated) {
      (try? ingredientRepository.fetchAll()) ?? []
    }.value

    let caches = await Task.detached(priority: .userInitiated) {
      let ingredientsByID = Dictionary(
        uniqueKeysWithValues: fetchedIngredients.compactMap { ingredient -> (Int64, Ingredient)? in
          guard let id = ingredient.id else { return nil }
          return (id, ingredient)
        })
      let matchesByGroup = AllergenSupport.groupMatchesByGroupID(in: fetchedIngredients)
      return (ingredientsByID, matchesByGroup)
    }.value

    allIngredients = fetchedIngredients
    ingredientByID = caches.0
    allergenGroupMatchesByID = caches.1

    do {
      let profile: HealthProfile? = try await Task.detached(priority: .userInitiated) {
        () throws -> HealthProfile? in
        guard try userDataRepository.hasCompletedOnboarding() else { return nil }
        return try userDataRepository.fetchHealthProfile()
      }.value

      guard let profile else {
        dailyCalories = goal.suggestedCalories
        return
      }

      goal = profile.goal
      dailyCalories = profile.dailyCalories ?? profile.goal.suggestedCalories
      selectedRestrictions = Set(profile.parsedDietaryRestrictions)
      selectedAllergens = Set(profile.parsedAllergenIds)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveProfile() {
    guard !isSaving else { return }
    isSaving = true

    let selectedRestrictions = Array(self.selectedRestrictions).sorted()
    let selectedAllergens = Array(self.selectedAllergens).sorted()
    let selectedGoal = goal
    let selectedCalories = dailyCalories
    let userDataRepository = deps.userDataRepository

    Task { @MainActor in
      defer { isSaving = false }

      do {
        let restrictionsJSON = try encodeJSON(selectedRestrictions)
        let allergensJSON = try encodeJSON(selectedAllergens)
        let split = selectedGoal.defaultMacroSplit

        let profile = HealthProfile(
          goal: selectedGoal,
          dailyCalories: selectedCalories,
          proteinPct: split.protein,
          carbsPct: split.carbs,
          fatPct: split.fat,
          dietaryRestrictions: restrictionsJSON,
          allergenIngredientIds: allergensJSON
        )

        try await Task.detached(priority: .userInitiated) {
          try userDataRepository.saveHealthProfile(profile)
        }.value

        onComplete()
        if !isRequired {
          dismiss()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
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
