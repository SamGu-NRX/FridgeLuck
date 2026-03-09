import SwiftUI

/// Health onboarding — 7-step flow.
struct OnboardingView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isRequired: Bool
  let onComplete: () -> Void

  // MARK: - State

  @State private var displayName = ""
  @State private var age: Int = 25
  @State private var goal: HealthGoal = .general
  @State private var dailyCalories: Int = HealthGoal.general.suggestedCalories
  @State private var selectedDiet: String = "classic"
  @State private var selectedAllergens: Set<Int64> = []
  @State private var allergenCatalog: AllergenCatalogIndex = .empty

  @State private var stepIndex = 0
  @State private var stepDirection: StepDirection = .forward
  @State private var isTransitioning = false
  @State private var isLoaded = false
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var validationMessage: String?
  @State private var showAllergenPicker = false

  @FocusState private var isNameFocused: Bool

  // MARK: - Step Definition

  private enum Step: Int, CaseIterable {
    case name
    case welcome
    case age
    case goal
    case calories
    case restrictions
    case allergens
  }

  private enum StepDirection {
    case forward
    case backward
  }

  private let dietOptions: [DietOption] = [
    .init(id: "classic", title: "Classic", subtitle: "No dietary restrictions", icon: .dietClassic),
    .init(
      id: "pescatarian", title: "Pescatarian", subtitle: "No meat, includes fish",
      icon: .dietPescatarian),
    .init(
      id: "vegetarian", title: "Vegetarian", subtitle: "No meat or fish", icon: .dietVegetarian),
    .init(id: "vegan", title: "Vegan", subtitle: "No animal products", icon: .dietVegan),
    .init(id: "keto", title: "Keto", subtitle: "Very low carb, high fat", icon: .dietKeto),
  ]

  private var currentStep: Step {
    Step(rawValue: stepIndex) ?? .name
  }

  private var totalSteps: Int {
    Step.allCases.count
  }

  private var progress: Double {
    Double(stepIndex + 1) / Double(totalSteps)
  }

  private var selectedAllergenIngredients: [Ingredient] {
    allergenCatalog.selectedIngredients(from: selectedAllergens)
  }

  private var normalizedName: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      topBar
      stepContentContainer
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      footer
    }
    .flPageBackground()
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
        catalog: allergenCatalog,
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
    .onChange(of: displayName) { _, _ in
      if validationMessage != nil {
        validationMessage = nil
      }
    }
  }

  // MARK: - Top Bar

  private var topBar: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack {
        if stepIndex > 0 {
          OnboardingBackButton {
            goBack()
          }
          .transition(.opacity)
        } else {
          Color.clear.frame(width: 40, height: 40)
        }

        Spacer()

        Text("Step \(stepIndex + 1) of \(totalSteps)")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)

        Spacer()

        if !isRequired {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(AppTheme.textSecondary)
              .frame(width: 40, height: 40)
          }
          .buttonStyle(.plain)
        } else {
          Color.clear.frame(width: 40, height: 40)
        }
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .animation(reduceMotion ? nil : AppMotion.onboardingStep, value: stepIndex)

      OnboardingProgressBar(
        progress: progress,
        reduceMotion: reduceMotion
      )
    }
    .padding(.top, AppTheme.Space.xs)
  }

  // MARK: - Step Content

  private var stepContentContainer: some View {
    ZStack {
      Group {
        switch currentStep {
        case .name:
          OnboardingNameStep(
            displayName: $displayName,
            isNameFocused: $isNameFocused,
            validationMessage: validationMessage
          )
        case .welcome:
          OnboardingWelcomeStep(displayName: normalizedName)
        case .age:
          OnboardingAgeStep(age: $age, reduceMotion: reduceMotion)
        case .goal:
          OnboardingGoalStep(goal: $goal)
        case .calories:
          OnboardingCalorieStep(dailyCalories: $dailyCalories, goal: goal)
        case .restrictions:
          OnboardingDietStep(
            options: dietOptions,
            selectedDiet: selectedDiet,
            onSelect: selectDiet
          )
        case .allergens:
          OnboardingAllergenStep(
            allergenGroupMatchesByID: allergenCatalog.groupMatchesByID,
            selectedAllergens: selectedAllergens,
            selectedAllergenIngredients: selectedAllergenIngredients,
            onToggleGroup: toggleAllergenGroup,
            onOpenPicker: { showAllergenPicker = true }
          )
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

  // MARK: - Footer

  private var footer: some View {
    OnboardingFooter(
      isSaving: isSaving,
      isTransitioning: isTransitioning,
      primaryButtonTitle: primaryButtonTitle,
      primaryButtonIcon: primaryButtonIcon,
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

  // MARK: - Navigation

  private func handlePrimaryAction() {
    guard !isTransitioning, !isSaving else { return }

    if currentStep == .name {
      guard validateName() else { return }
    }

    if stepIndex < totalSteps - 1 {
      if currentStep == .name {
        isNameFocused = false
      }
      setStep(stepIndex + 1, direction: .forward)
    } else {
      saveProfile()
    }
  }

  private func goBack() {
    guard stepIndex > 0, !isTransitioning, !isSaving else { return }
    isNameFocused = false
    setStep(stepIndex - 1, direction: .backward)
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

      if Step(rawValue: clamped) == .name {
        isNameFocused = true
      }
    }
  }

  // MARK: - Validation

  private func validateName() -> Bool {
    guard !normalizedName.isEmpty else {
      validationMessage = "Please enter your name to continue."
      return false
    }
    validationMessage = nil
    return true
  }

  // MARK: - Toggles

  private func selectDiet(_ id: String) {
    withAnimation(reduceMotion ? nil : AppMotion.selectionPress) {
      selectedDiet = id
    }
  }

  private func toggleAllergenGroup(_ group: AllergenGroupDefinition) {
    let ids = allergenCatalog.groupMatchesByID[group.id] ?? []
    guard !ids.isEmpty else { return }

    withAnimation(reduceMotion ? nil : AppMotion.chipReflow) {
      let selectedCount = selectedAllergens.intersection(ids).count
      if selectedCount == ids.count {
        selectedAllergens.subtract(ids)
      } else {
        selectedAllergens.formUnion(ids)
      }
    }
  }

  // MARK: - Data Loading

  private func loadProfile() async {
    let ingredientRepository = deps.ingredientRepository
    let userDataRepository = deps.userDataRepository

    let catalog = await Task.detached(priority: .userInitiated) {
      let fetchedIngredients = (try? ingredientRepository.fetchAll()) ?? []
      return AllergenSupport.buildCatalog(from: fetchedIngredients)
    }.value

    allergenCatalog = catalog

    do {
      let profile: HealthProfile = try await Task.detached(priority: .userInitiated) {
        try userDataRepository.fetchHealthProfile()
      }.value

      displayName = profile.displayName
      age = profile.age ?? 25
      goal = profile.goal
      dailyCalories = profile.dailyCalories ?? profile.goal.suggestedCalories
      selectedDiet = profile.selectedDietID ?? "classic"
      selectedAllergens = Set(profile.parsedAllergenIds)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Save

  private func saveProfile() {
    guard !isSaving else { return }
    guard validateName() else { return }
    isSaving = true

    let dietArray = selectedDiet == "classic" ? [String]() : [selectedDiet]
    let selectedAllergens = Array(self.selectedAllergens).sorted()
    let selectedName = normalizedName
    let selectedAge = age
    let selectedGoal = goal
    let selectedCalories = dailyCalories
    let userDataRepository = deps.userDataRepository

    Task { @MainActor in
      defer { isSaving = false }

      do {
        let restrictionsJSON = try encodeJSON(dietArray)
        let allergensJSON = try encodeJSON(selectedAllergens)
        let split = selectedGoal.defaultMacroSplit

        let profile = HealthProfile(
          displayName: selectedName,
          age: selectedAge,
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
