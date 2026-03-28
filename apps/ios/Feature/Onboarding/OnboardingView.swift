import SwiftUI

#if canImport(HealthKitUI)
  import HealthKitUI
#endif

enum AppleHealthOnboardingState: Equatable {
  case readyToRequest
  case requesting
  case connected
  case needsSettings
  case unavailable

  static func resolve(
    authorizationStatus: AppPermissionStatus,
    requestStatus: AppleHealthAuthorizationRequestStatus
  ) -> AppleHealthOnboardingState {
    switch authorizationStatus {
    case .authorized, .limited:
      return .connected
    case .unavailable:
      return .unavailable
    case .denied, .restricted:
      return .needsSettings
    case .notDetermined:
      switch requestStatus {
      case .shouldRequest, .unknown, .failed:
        return .readyToRequest
      case .unnecessary:
        return .needsSettings
      case .unavailable:
        return .unavailable
      }
    }
  }
}

/// Health onboarding — hero welcome, profile setup, feature highlights,
/// Apple Health, then app handoff.
struct OnboardingView: View {
  private enum Chrome {
    static let topBarHeight: CGFloat = 64
  }

  private enum Timing {
    static let reducedMotionStepTransitionLockNanoseconds: UInt64 = 10_000_000
    static let stepTransitionLockNanoseconds: UInt64 = 280_000_000
    static let reducedMotionNameFocusSettleNanoseconds: UInt64 = 90_000_000
    static let nameFocusSettleNanoseconds: UInt64 = 180_000_000
  }

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
  @State private var previousStep: OnboardingStep = .welcome
  @State private var stepDirection: StepDirection = .forward
  @State private var isTransitioning = false
  @State private var isLoaded = false
  @State private var isSaving = false
  @State private var isAllergenCatalogLoaded = false
  @State private var isAllergenCatalogLoading = false
  @State private var errorMessage: String?
  @State private var validationMessage: String?
  @State private var showAllergenPicker = false
  @State private var appleHealthState: AppleHealthOnboardingState = .readyToRequest
  @State private var appleHealthRequestTrigger = 0
  @State private var appleHealthInlineErrorMessage: String?
  @State private var setupBridgeState: SetupBridgeState = .idle
  @State private var setupBridgeVisitToken = 0
  @State private var pendingNameFocusTask: Task<Void, Never>?

  // Kitchen inventory capture state
  @State private var fridgeCapturedImages: [UIImage] = []
  @State private var pantryCapturedImages: [UIImage] = []
  @State private var kitchenDetections: [Detection] = []
  @State private var kitchenConfirmedIds: Set<Int64> = []
  @State private var isAnalyzingKitchen = false

  @FocusState private var isNameFocused: Bool

  // MARK: - Step Definition

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

  private var currentStep: OnboardingStep {
    OnboardingStep(rawValue: stepIndex) ?? .welcome
  }

  private var totalSteps: Int {
    OnboardingStep.allCases.count
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
    default:
      return stepIndex > 0
    }
  }

  // MARK: - Body

  var body: some View {
    applyAppleHealthAuthorizationRequest(to: rootContent)
  }

  private var rootContent: some View {
    VStack(spacing: 0) {
      topBar
        .frame(height: Chrome.topBarHeight, alignment: .top)
      stepContentContainer
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      footer
    }
    .flPageBackground(renderMode: currentStep.backgroundRenderMode)
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
    .task(id: currentStep) {
      if currentStep.shouldWarmAllergenCatalog {
        await preloadAllergenCatalogIfNeeded()
      }
      if currentStep == .healthPermission {
        await refreshAppleHealthState(showPreflightErrors: true)
      }
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
      guard newPhase == .active, currentStep == .healthPermission else { return }
      Task { await refreshAppleHealthState(showPreflightErrors: true) }
    }
    .onDisappear {
      pendingNameFocusTask?.cancel()
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

      OnboardingProgressBar(
        progress: progress,
        reduceMotion: reduceMotion
      )
    }
    .padding(.top, AppTheme.Space.xs)
    .opacity(currentStep.showsTopBarContent ? 1 : 0)
    .allowsHitTesting(currentStep.showsTopBarContent)
    .accessibilityHidden(!currentStep.showsTopBarContent)
  }

  // MARK: - Step Content

  private var stepContentContainer: some View {
    ZStack {
      Group {
        switch currentStep {
        case .welcome:
          OnboardingWelcomeHeroStep(
            onContinueWithoutApple: {
              setStep(OnboardingStep.name.rawValue, direction: .forward)
            }
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
            isCatalogReady: isAllergenCatalogLoaded,
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
            state: appleHealthState,
            didChooseSkip: firstRunExperienceStore.appleHealthChoice == .skipped
              && appleHealthState != .connected,
            inlineErrorMessage: appleHealthInlineErrorMessage
          )

        case .virtualFridgeIntro:
          OnboardingVirtualFridgeIntroStep()

        case .fridgeCapture:
          OnboardingFridgeCaptureStep(capturedImages: $fridgeCapturedImages)

        case .pantryCapture:
          OnboardingPantryCaptureStep(capturedImages: $pantryCapturedImages)

        case .kitchenReview:
          OnboardingKitchenReviewStep(
            fridgeCapturedImages: fridgeCapturedImages,
            pantryCapturedImages: pantryCapturedImages,
            detections: $kitchenDetections,
            confirmedIds: $kitchenConfirmedIds,
            isAnalyzing: $isAnalyzingKitchen,
            onConfirm: commitKitchenInventory
          )

        case .setupBridge:
          OnboardingSetupBridgeStep(
            displayName: normalizedName,
            goal: goal
          )
          .id(setupBridgeVisitToken)

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
    OnboardingTransitionPolicy.transition(
      from: previousStep,
      to: currentStep,
      isForward: stepDirection == .forward,
      reduceMotion: reduceMotion
    )
  }

  // MARK: - Footer

  private var footer: some View {
    Group {
      if currentStep.showsFooterActions {
        OnboardingFooter(
          isSaving: isSaving || appleHealthState == .requesting,
          isTransitioning: isTransitioning,
          primaryButtonTitle: primaryButtonTitle,
          primaryButtonIcon: primaryButtonIcon,
          secondaryButtonTitle: secondaryButtonTitle,
          secondaryButtonIcon: secondaryButtonIcon,
          onPrimaryAction: handlePrimaryAction,
          onSecondaryAction: handleSecondaryAction
        )
      } else {
        Color.clear
          .frame(height: OnboardingFooter.reservedHeight)
          .accessibilityHidden(true)
      }
    }
  }

  private var isReadyForPrimaryAction: Bool {
    !isTransitioning && !isSaving && appleHealthState != .requesting
  }

  private var primaryButtonTitle: String {
    switch currentStep {
    case .healthPermission:
      switch appleHealthState {
      case .connected, .unavailable:
        return "Continue"
      case .needsSettings:
        return "Open Settings"
      case .readyToRequest, .requesting:
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
      switch appleHealthState {
      case .connected:
        return "checkmark.circle.fill"
      case .unavailable:
        return "arrow.right"
      case .needsSettings:
        return "gearshape.fill"
      case .readyToRequest, .requesting:
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
    guard appleHealthState != .connected && appleHealthState != .unavailable else { return nil }
    return "Skip for now"
  }

  private var secondaryButtonIcon: String? {
    secondaryButtonTitle == nil ? nil : "arrow.uturn.right"
  }

  // MARK: - Navigation

  private func handlePrimaryAction() {
    guard isReadyForPrimaryAction else { return }

    switch currentStep {
    case .welcome:
      break

    case .name:
      guard validateName() else { return }
      clearNameFocus()
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
    if currentStep == .setupBridge {
      guard !isTransitioning else { return }
      setupBridgeState = .idle
      isSaving = false
    } else {
      guard isReadyForPrimaryAction else { return }
    }
    guard stepIndex > 0 else { return }
    clearNameFocus()
    setStep(stepIndex - 1, direction: .backward)
  }

  private func setStep(_ newValue: Int, direction: StepDirection) {
    let clamped = min(max(newValue, 0), totalSteps - 1)
    guard clamped != stepIndex else { return }
    guard !isTransitioning else { return }

    let nextStep = OnboardingStep(rawValue: clamped) ?? .welcome
    let performanceLabel = "step_transition_\(currentStep.rawValue)_\(nextStep.rawValue)"
    let stepTransitionStart = OnboardingPerformanceProfiler.begin(performanceLabel)

    previousStep = currentStep
    stepDirection = direction
    isTransitioning = true

    if nextStep == .setupBridge {
      setupBridgeState = .idle
      isSaving = false
      setupBridgeVisitToken += 1
    }

    if reduceMotion {
      stepIndex = clamped
    } else {
      withAnimation(AppMotion.onboardingStep) {
        stepIndex = clamped
      }
    }

    let lockDurationNanoseconds =
      reduceMotion
      ? Timing.reducedMotionStepTransitionLockNanoseconds
      : Timing.stepTransitionLockNanoseconds
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: lockDurationNanoseconds)
      isTransitioning = false
      scheduleNameFocusIfNeeded(for: nextStep)
      OnboardingPerformanceProfiler.end(performanceLabel, from: stepTransitionStart)
    }
  }

  private func clearNameFocus() {
    pendingNameFocusTask?.cancel()
    pendingNameFocusTask = nil
    isNameFocused = false
  }

  private func scheduleNameFocusIfNeeded(for step: OnboardingStep) {
    pendingNameFocusTask?.cancel()
    pendingNameFocusTask = nil

    guard step == .name else { return }

    pendingNameFocusTask = Task { @MainActor in
      let focusStart = OnboardingPerformanceProfiler.begin("name_focus_request")
      let focusDelayNanoseconds =
        reduceMotion
        ? Timing.reducedMotionNameFocusSettleNanoseconds
        : Timing.nameFocusSettleNanoseconds

      try? await Task.sleep(nanoseconds: focusDelayNanoseconds)
      guard !Task.isCancelled else { return }
      guard currentStep == .name else { return }
      guard !isTransitioning else { return }

      await Task.yield()
      guard !Task.isCancelled else { return }
      guard currentStep == .name else { return }

      isNameFocused = true
      OnboardingPerformanceProfiler.end("name_focus_request", from: focusStart)
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
    let loadStart = OnboardingPerformanceProfiler.begin("onboarding_initial_load")
    let userDataRepository = deps.userDataRepository

    if currentStep == .healthPermission {
      await refreshAppleHealthState(showPreflightErrors: true)
    }

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

    OnboardingPerformanceProfiler.end("onboarding_initial_load", from: loadStart)
  }

  private func preloadAllergenCatalogIfNeeded() async {
    guard !isAllergenCatalogLoaded, !isAllergenCatalogLoading else { return }

    isAllergenCatalogLoading = true
    let catalog = await OnboardingAllergenCatalogLoader.load(from: deps.ingredientRepository)
    allergenCatalog = catalog
    isAllergenCatalogLoaded = true
    isAllergenCatalogLoading = false
  }

  // MARK: - Apple Health

  private func refreshAppleHealthState(showPreflightErrors: Bool) async {
    let requestStatus = await deps.appleHealthService.authorizationRequestStatus()
    let authorizationStatus = deps.appleHealthService.authorizationStatus()
    appleHealthState = AppleHealthOnboardingState.resolve(
      authorizationStatus: authorizationStatus,
      requestStatus: requestStatus
    )

    if showPreflightErrors {
      switch requestStatus {
      case .failed(let message):
        appleHealthInlineErrorMessage =
          "Apple Health could not be checked right now. \(message)"
      default:
        appleHealthInlineErrorMessage = nil
      }
    }

    if appleHealthState == .connected {
      firstRunExperienceStore.appleHealthChoice = .connected
      appleHealthInlineErrorMessage = nil
    }
  }

  private func handleAppleHealthPrimaryAction() {
    appleHealthInlineErrorMessage = nil

    switch appleHealthState {
    case .connected, .unavailable:
      setStep(stepIndex + 1, direction: .forward)
    case .needsSettings:
      AppPermissionCenter.openAppSettings()
    case .readyToRequest:
      appleHealthState = .requesting
      appleHealthRequestTrigger += 1
    case .requesting:
      break
    }
  }

  @MainActor
  private func handleAppleHealthAuthorizationCompletion(_ result: Result<Bool, Error>) async {
    defer {
      if appleHealthState == .requesting {
        appleHealthState = .readyToRequest
      }
    }

    switch result {
    case .success(let granted):
      await refreshAppleHealthState(showPreflightErrors: true)
      if appleHealthState == .connected {
        setStep(stepIndex + 1, direction: .forward)
      } else if !granted {
        firstRunExperienceStore.appleHealthChoice = .unresolved
      }
    case .failure(let error):
      await refreshAppleHealthState(showPreflightErrors: true)
      appleHealthInlineErrorMessage =
        "Apple Health could not be connected right now. \(error.localizedDescription)"
      firstRunExperienceStore.appleHealthChoice = .unresolved
    }
  }

  @ViewBuilder
  private func applyAppleHealthAuthorizationRequest<Content: View>(to content: Content) -> some View
  {
    #if canImport(HealthKitUI)
      if let context = deps.appleHealthAuthorizationContext {
        content.healthDataAccessRequest(
          store: context.healthStore,
          shareTypes: context.requestShareTypes,
          readTypes: context.requestReadTypes,
          trigger: appleHealthRequestTrigger
        ) { result in
          Task { @MainActor in
            await handleAppleHealthAuthorizationCompletion(result)
          }
        }
      } else {
        content
      }
    #else
      content
    #endif
  }

  // MARK: - Setup Bridge

  private func runSetupBridgeIfNeeded() async {
    guard setupBridgeState == .idle else { return }
    guard validateName() else { return }

    setupBridgeState = .running
    isSaving = true

    let bridgeMinimumDelay =
      reduceMotion
      ? OnboardingSetupBridgeTiming.reducedMotionDuration
      : OnboardingSetupBridgeTiming.totalVisualDuration

    do {
      async let saveTask: Void = persistProfile()
      async let minimumDelay: Void = Task.sleep(nanoseconds: bridgeMinimumDelay)
      _ = try await saveTask
      try await minimumDelay
      try Task.checkCancellation()

      isSaving = false
      setupBridgeState = .complete
      setStep(stepIndex + 1, direction: .forward)
    } catch {
      isSaving = false
      setupBridgeState = .idle
      if !(error is CancellationError) {
        errorMessage = error.localizedDescription
      }
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

  // MARK: - Kitchen Inventory Commit

  private func commitKitchenInventory() {
    let confirmedDetections = kitchenDetections.filter {
      kitchenConfirmedIds.contains($0.ingredientId)
    }
    guard !confirmedDetections.isEmpty else {
      setStep(OnboardingStep.setupBridge.rawValue, direction: .forward)
      return
    }

    Task {
      do {
        _ = try deps.inventoryIntakeService.ingestConfirmedScan(
          detections: confirmedDetections,
          confirmedIngredientIDs: kitchenConfirmedIds,
          selectedIngredientByDetection: [:],
          sourceRef: "onboarding_kitchen_capture_\(UUID().uuidString)"
        )
      } catch {
        // Non-blocking: inventory seeding failure shouldn't stop onboarding
        errorMessage = nil
      }
      setStep(OnboardingStep.setupBridge.rawValue, direction: .forward)
    }
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
