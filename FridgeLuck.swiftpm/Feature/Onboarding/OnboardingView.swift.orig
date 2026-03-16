import AuthenticationServices
import SwiftUI

/// Health onboarding — hero welcome, profile setup, feature highlights,
/// Apple Health, then app handoff.
struct OnboardingView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

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
  @State private var appleHealthStatus: AppPermissionStatus = .notDetermined
  @State private var appleHealthRequestInFlight = false
  @State private var setupBridgeState: SetupBridgeState = .idle

  @FocusState private var isNameFocused: Bool

  // MARK: - Step Definition

  private enum Step: Int, CaseIterable {
    case welcome
    case name
    case personalWelcome
    case age
    case goal
    case featureScan
    case calories
    case restrictions
    case featureChef
    case allergens
    case healthValue
    case healthPermission
    case setupBridge
    case handoff
  }

  private enum StepDirection {
    case forward
    case backward
  }

  private enum SetupBridgeState {
    case idle
    case running
    case complete
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
    Step(rawValue: stepIndex) ?? .welcome
  }

  private var totalSteps: Int {
    Step.allCases.count
  }

  private var progress: Double {
    guard stepIndex > 0 else { return 0 }
    return Double(stepIndex) / Double(totalSteps - 1)
  }

  private var selectedAllergenIngredients: [Ingredient] {
    allergenCatalog.selectedIngredients(from: selectedAllergens)
  }

  private var normalizedName: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canGoBack: Bool {
    switch currentStep {
    case .welcome:
      return false
    case .setupBridge:
      return false
    default:
      return stepIndex > 0
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      if currentStep != .welcome {
        topBar
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
      stepContentContainer
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      footer
    }
    .flPageBackground()
    .animation(reduceMotion ? nil : AppMotion.onboardingStep, value: currentStep == .welcome)
    .alert(
      "Unable to Continue",
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
    .task(id: stepIndex) {
      guard currentStep == .setupBridge else { return }
      await runSetupBridgeIfNeeded()
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
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      refreshAppleHealthStatus()
    }
  }

  // MARK: - Top Bar

  private var topBar: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack {
        if canGoBack {
          OnboardingBackButton {
            goBack()
          }
          .transition(.opacity)
        } else {
          Color.clear.frame(width: 40, height: 40)
        }

        Spacer()

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
        case .welcome:
          OnboardingWelcomeHeroStep(
            onContinueWithoutApple: {
              setStep(Step.name.rawValue, direction: .forward)
            },
            onAppleSignInRequest: configureAppleSignInRequest,
            onAppleSignInCompletion: handleAppleSignInCompletion
          )

        case .name:
          OnboardingNameStep(
            displayName: $displayName,
            isNameFocused: $isNameFocused,
            validationMessage: validationMessage
          )

        case .personalWelcome:
          OnboardingPersonalWelcomeStep(displayName: normalizedName)

        case .age:
          OnboardingAgeStep(age: $age, reduceMotion: reduceMotion)

        case .goal:
          OnboardingGoalStep(goal: $goal)

        case .featureScan:
          OnboardingFeatureScanStep()

        case .calories:
          OnboardingCalorieStep(dailyCalories: $dailyCalories, goal: goal)

        case .restrictions:
          OnboardingDietStep(
            options: dietOptions,
            selectedDiet: selectedDiet,
            onSelect: selectDiet
          )

        case .featureChef:
          OnboardingFeatureChefStep()

        case .allergens:
          OnboardingAllergenStep(
            allergenGroupMatchesByID: allergenCatalog.groupMatchesByID,
            selectedAllergens: selectedAllergens,
            selectedAllergenIngredients: selectedAllergenIngredients,
            onToggleGroup: toggleAllergenGroup,
            onOpenPicker: { showAllergenPicker = true }
          )

        case .healthValue:
          OnboardingAppleHealthValueStep()

        case .healthPermission:
          OnboardingAppleHealthPermissionStep(
            status: appleHealthStatus,
            isRequestInFlight: appleHealthRequestInFlight,
            didChooseSkip: firstRunExperienceStore.appleHealthChoice == .skipped
          )

        case .setupBridge:
          OnboardingSetupBridgeStep(
            displayName: normalizedName,
            goal: goal
          )

        case .handoff:
          OnboardingHandoffStep(
            displayName: normalizedName,
            goal: goal,
            dailyCalories: dailyCalories,
            selectedDiet: selectedDiet,
            allergenCount: selectedAllergens.count,
            healthConnected: firstRunExperienceStore.appleHealthChoice == .connected
          )
        }
      }
      .id(currentStep.rawValue)
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

  @ViewBuilder
  private var footer: some View {
    if currentStep == .setupBridge || currentStep == .welcome {
      EmptyView()
    } else {
      OnboardingFooter(
        isSaving: isSaving || appleHealthRequestInFlight,
        isTransitioning: isTransitioning,
        primaryButtonTitle: primaryButtonTitle,
        primaryButtonIcon: primaryButtonIcon,
        secondaryButtonTitle: secondaryButtonTitle,
        secondaryButtonIcon: secondaryButtonIcon,
        onPrimaryAction: handlePrimaryAction,
        onSecondaryAction: handleSecondaryAction
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var primaryButtonTitle: String {
    switch currentStep {
    case .healthPermission:
      switch appleHealthStatus {
      case .authorized, .unavailable:
        return "Continue"
      case .denied:
        return "Open Settings"
      default:
        return "Connect Apple Health"
      }
    case .handoff:
      return "Start Guided Demo"
    default:
      return "Continue"
    }
  }

  private var primaryButtonIcon: String {
    switch currentStep {
    case .healthPermission:
      switch appleHealthStatus {
      case .authorized:
        return "checkmark.circle.fill"
      case .unavailable:
        return "arrow.right"
      case .denied:
        return "gearshape.fill"
      default:
        return "heart.text.square.fill"
      }
    case .handoff:
      return "arrow.right.circle.fill"
    default:
      return "arrow.right"
    }
  }

  private var secondaryButtonTitle: String? {
    guard currentStep == .healthPermission else { return nil }
    guard appleHealthStatus != .authorized && appleHealthStatus != .unavailable else { return nil }
    return "Skip for now"
  }

  private var secondaryButtonIcon: String? {
    secondaryButtonTitle == nil ? nil : "arrow.uturn.right"
  }

  // MARK: - Navigation

  private func handlePrimaryAction() {
    guard !isTransitioning, !isSaving, !appleHealthRequestInFlight else { return }

    switch currentStep {
    case .welcome:
      break

    case .name:
      guard validateName() else { return }
      isNameFocused = false
      setStep(stepIndex + 1, direction: .forward)

    case .healthPermission:
      handleAppleHealthPrimaryAction()

    case .handoff:
      completeFlow()

    default:
      setStep(stepIndex + 1, direction: .forward)
    }
  }

  private func handleSecondaryAction() {
    guard currentStep == .healthPermission else { return }
    firstRunExperienceStore.appleHealthChoice = .skipped
    setStep(stepIndex + 1, direction: .forward)
  }

  private func goBack() {
    guard !isTransitioning, !isSaving, !appleHealthRequestInFlight else { return }
    guard stepIndex > 0 else { return }
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

  // MARK: - Apple Sign In

  private func configureAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
    request.requestedScopes = [.fullName]
  }

  private func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
    switch result {
    case .success(let authorization):
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
        errorMessage = "Apple sign-in returned an unexpected credential."
        return
      }

      UserDefaults.standard.set(credential.user, forKey: "appleUserIdentifier")
      if let givenName = credential.fullName?.givenName, !givenName.isEmpty {
        displayName = givenName
      }
      setStep(Step.name.rawValue, direction: .forward)

    case .failure(let error):
      if let authError = error as? ASAuthorizationError {
        switch authError.code {
        case .canceled:
          return
        case .failed:
          errorMessage =
            "Apple sign-in failed. If this is a personal team build, continue without Apple for local testing."
        case .invalidResponse:
          errorMessage =
            "Apple sign-in returned an invalid response. Try again."
        case .notHandled:
          errorMessage =
            "Apple sign-in could not be completed here. Try again from a signed-in device."
        case .notInteractive,
          .matchedExcludedCredential,
          .credentialImport,
          .credentialExport,
          .preferSignInWithApple,
          .deviceNotConfiguredForPasskeyCreation:
          errorMessage = authError.localizedDescription
        case .unknown:
          errorMessage =
            "Apple sign-in is not configured for this build. Continue without Apple for local testing, or use a paid Apple Developer team with the capability enabled."
        @unknown default:
          errorMessage = authError.localizedDescription
        }
      } else {
        errorMessage = error.localizedDescription
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
    refreshAppleHealthStatus()

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

  // MARK: - Apple Health

  private func refreshAppleHealthStatus() {
    appleHealthStatus = deps.appleHealthService.authorizationStatus()
    if appleHealthStatus == .authorized {
      firstRunExperienceStore.appleHealthChoice = .connected
    }
  }

  private func handleAppleHealthPrimaryAction() {
    switch appleHealthStatus {
    case .authorized, .unavailable:
      setStep(stepIndex + 1, direction: .forward)
    case .denied:
      AppPermissionCenter.openAppSettings()
    default:
      requestAppleHealthAuthorization()
    }
  }

  private func requestAppleHealthAuthorization() {
    appleHealthRequestInFlight = true

    Task { @MainActor in
      defer { appleHealthRequestInFlight = false }

      let result = await deps.appleHealthService.requestAuthorization()
      appleHealthStatus = deps.appleHealthService.authorizationStatus()

      switch result {
      case .granted:
        firstRunExperienceStore.appleHealthChoice = .connected
        setStep(stepIndex + 1, direction: .forward)
      case .limited:
        firstRunExperienceStore.appleHealthChoice = .connected
        setStep(stepIndex + 1, direction: .forward)
      case .denied:
        firstRunExperienceStore.appleHealthChoice = .unresolved
      case .unavailable:
        appleHealthStatus = .unavailable
        firstRunExperienceStore.appleHealthChoice = .unresolved
        setStep(stepIndex + 1, direction: .forward)
      }
    }
  }

  // MARK: - Setup Bridge

  private func runSetupBridgeIfNeeded() async {
    guard setupBridgeState == .idle else { return }
    guard validateName() else { return }

    setupBridgeState = .running
    isSaving = true

    let bridgeMinimumDelay: UInt64 = reduceMotion ? 250_000_000 : 2_200_000_000

    do {
      async let saveTask: Void = persistProfile()
      async let minimumDelay: Void = Task.sleep(nanoseconds: bridgeMinimumDelay)
      _ = try await saveTask
      try await minimumDelay

      isSaving = false
      setupBridgeState = .complete
      setStep(stepIndex + 1, direction: .forward)
    } catch {
      isSaving = false
      setupBridgeState = .idle
      errorMessage = error.localizedDescription
    }
  }

  private func persistProfile() async throws {
    let dietArray = selectedDiet == "classic" ? [String]() : [selectedDiet]
    let selectedAllergens = Array(self.selectedAllergens).sorted()
    let selectedName = normalizedName
    let selectedAge = age
    let selectedGoal = goal
    let selectedCalories = dailyCalories
    let userDataRepository = deps.userDataRepository

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
  }

  // MARK: - Completion

  private func completeFlow() {
    onComplete()
    if !isRequired {
      dismiss()
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
