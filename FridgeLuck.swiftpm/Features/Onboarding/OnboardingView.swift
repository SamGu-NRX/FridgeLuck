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

    var icon: String {
      switch self {
      case .goals: return "target"
      case .restrictions: return "slider.horizontal.3"
      case .allergens: return "exclamationmark.shield"
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
      if currentStep == .goals {
        goalStep.transition(stepTransition)
      }
      if currentStep == .restrictions {
        restrictionStep.transition(stepTransition)
      }
      if currentStep == .allergens {
        allergenStep.transition(stepTransition)
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

  // MARK: - Header (with arc progress)

  private var header: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .center) {
        HStack(spacing: AppTheme.Space.sm) {
          // Arc progress indicator
          FLArcIndicator(
            progress: Double(stepIndex + 1) / Double(totalSteps),
            steps: totalSteps,
            size: 40
          )
          .animation(reduceMotion ? nil : AppMotion.onboardingStep, value: stepIndex)

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("Step \(stepIndex + 1) of \(totalSteps)")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        Spacer()

        if isRequired {
          FLStatusPill(text: "New", kind: .warning)
        }
      }

      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(currentStep.title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
        Text(currentStep.subtitle)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, AppTheme.Space.sm)
    .frame(maxWidth: .infinity, minHeight: Layout.headerMinHeight, alignment: .topLeading)
  }

  // MARK: - Goal Step (card rotations + card-free calorie display)

  private var goalStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Pick your primary nutrition direction")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("You can update this anytime from profile settings.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)

        // Goal cards with slight rotation (collage feel)
        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppTheme.Space.sm
        ) {
          goalCard(.general, accent: AppTheme.sage, rotation: -0.8)
          goalCard(.weightLoss, accent: AppTheme.accent, rotation: 1.0)
          goalCard(.muscleGain, accent: AppTheme.oat, rotation: 0.5)
          goalCard(.maintenance, accent: AppTheme.dustyRose, rotation: -1.2)
        }

        FLWaveDivider()
          .padding(.vertical, AppTheme.Space.sm)

        // Card-free calorie display: just a massive serif number on warm background
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("DAILY CALORIES")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.5)

          HStack(spacing: AppTheme.Space.sm) {
            Button {
              dailyCalories = max(1000, dailyCalories - 50)
            } label: {
              Image(systemName: "minus")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("\(dailyCalories)")
              .font(.system(size: 48, weight: .bold, design: .serif))
              .foregroundStyle(AppTheme.textPrimary)
              .frame(maxWidth: .infinity)
              .contentTransition(.numericText())

            Button {
              dailyCalories = min(4500, dailyCalories + 50)
            } label: {
              Image(systemName: "plus")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
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
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func goalCard(_ value: HealthGoal, accent: Color, rotation: Double) -> some View {
    let selected = goal == value

    return Button {
      goal = value
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Circle()
          .fill(selected ? accent : AppTheme.oat.opacity(0.35))
          .frame(width: 12, height: 12)
        Text(value.displayName)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
        Text("\(value.suggestedCalories) kcal")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 80)
      .padding(AppTheme.Space.md)
      .background(
        selected ? accent.opacity(0.10) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(selected ? accent.opacity(0.40) : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: selected ? 8 : 4, x: 0, y: selected ? 4 : 2)
      .rotationEffect(.degrees(rotation), anchor: .center)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Restriction Step (lighter, no card-in-card)

  private var restrictionStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Choose your dietary constraints")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("Filter recipes to match how you eat.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)

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
                  .font(AppTheme.Typography.label)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              }
              .foregroundStyle(selected ? AppTheme.textPrimary : AppTheme.textSecondary)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.sm)
              .background(
                selected ? AppTheme.accent.opacity(0.14) : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
              )
              .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                  .stroke(
                    selected ? AppTheme.accent : AppTheme.oat.opacity(0.30),
                    lineWidth: 1)
              )
            }
            .buttonStyle(.plain)
          }
        }

        if !selectedRestrictions.isEmpty {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text("ACTIVE FILTERS")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .kerning(1.2)

            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(Array(selectedRestrictions.sorted()), id: \.self) { restriction in
                Text(restriction.replacingOccurrences(of: "_", with: " ").capitalized)
                  .font(AppTheme.Typography.label)
                  .padding(.horizontal, AppTheme.Space.sm)
                  .padding(.vertical, AppTheme.Space.chipVertical)
                  .foregroundStyle(AppTheme.accent)
                  .background(AppTheme.accent.opacity(0.12), in: Capsule())
              }
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  // MARK: - Allergen Step (lighter card nesting)

  private var allergenStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("Start with common allergens")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Tap any group below to add or remove matching ingredients.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }

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

        Button {
          showAllergenPicker = true
        } label: {
          Label("Open Full Allergen Picker", systemImage: "magnifyingglass")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)

        FLWaveDivider()

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("SELECTED ALLERGENS")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          Text("\(selectedAllergens.count) selected")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)

          if selectedAllergenIngredients.isEmpty {
            Text("No allergens selected yet.")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
          } else {
            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(Array(selectedAllergenIngredients.prefix(40)), id: \.id) { ingredient in
                Text(ingredient.displayName)
                  .font(AppTheme.Typography.bodySmall)
                  .padding(.horizontal, AppTheme.Space.sm)
                  .padding(.vertical, AppTheme.Space.chipVertical)
                  .background(
                    FLOrganicBlob(seed: ingredient.displayName.hashValue)
                      .fill(AppTheme.accent.opacity(0.12))
                  )
              }
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
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
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(group.title)
            .font(AppTheme.Typography.label)
            .lineLimit(1)
            .foregroundStyle(AppTheme.textPrimary)
          Text(isSelected ? "\(selectedCount) selected" : group.subtitle)
            .font(AppTheme.Typography.labelSmall)
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
        isSelected ? AppTheme.accent.opacity(0.14) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .opacity(matchedIDs.isEmpty ? 0.75 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(matchedIDs.isEmpty)
  }

  // MARK: - Footer

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
          .tint(AppTheme.accent)
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.vertical, AppTheme.Space.sm)
    .background(AppTheme.bg)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(AppTheme.oat.opacity(0.25))
        .frame(height: 1)
    }
  }

  // MARK: - Helpers

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
