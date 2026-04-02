import SwiftUI

struct SettingsNutritionTargetsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = HealthProfile.default
  @State private var selectedPreset: HealthGoal?
  @State private var dailyCalories = 2000
  @State private var proteinPercent = 25
  @State private var carbsPercent = 45
  @State private var fatPercent = 30
  @State private var validationMessage: String?
  @State private var appeared = false

  private var isCustom: Bool { selectedPreset == nil }
  private var macroTotal: Int { proteinPercent + carbsPercent + fatPercent }

  private var saveEnabled: Bool {
    !isCustom || macroTotal == 100
  }

  private let columns = [
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
  ]

  private var customControlsTransition: AnyTransition {
    reduceMotion ? .opacity : .nutritionCustomControls
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Choose your goal")
          .font(.system(.subheadline, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
          ForEach(HealthGoal.allCases, id: \.self) { goal in
            goalCard(goal)
              .onTapGesture { selectPreset(goal) }
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        customCard()
          .padding(.horizontal, AppTheme.Space.page)

        if let validationMessage {
          Text(validationMessage)
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, AppTheme.Space.page)
        }
      }
      .padding(.vertical, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.sm)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .flSettingsBottomActionBar {
      FLPrimaryButton("Save", isEnabled: saveEnabled, action: save)
    }
    .navigationTitle("Nutrition Targets")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task { load() }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  private func goalCard(_ goal: HealthGoal) -> some View {
    let isSelected = selectedPreset == goal
    let split = goal.defaultMacroSplit
    let p = Int((split.protein * 100).rounded())
    let c = Int((split.carbs * 100).rounded())
    let f = Int((split.fat * 100).rounded())

    return VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Image(systemName: goal.icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)

      Text(goal.displayName)
        .font(.system(.subheadline, design: .serif, weight: .semibold))
        .foregroundStyle(AppTheme.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      Text("\(goal.suggestedCalories) kcal")
        .font(AppTheme.Typography.settingsCaption)
        .foregroundStyle(AppTheme.textSecondary)

      MacroSplitBar(protein: p, carbs: c, fat: f)

      HStack(spacing: 0) {
        macroLabel("P\(p)", color: AppTheme.macroProtein)
        Text("  ")
        macroLabel("C\(c)", color: AppTheme.macroCarbs)
        Text("  ")
        macroLabel("F\(f)", color: AppTheme.macroFat)
      }
      .font(AppTheme.Typography.labelSmall)
    }
    .padding(AppTheme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(isSelected ? AppTheme.accent.opacity(0.06) : AppTheme.surfaceElevated)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(
          isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.22), lineWidth: isSelected ? 2 : 1)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(goal.displayName), \(goal.suggestedCalories) calories, protein \(p)%, carbs \(c)%, fat \(f)%"
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func macroLabel(_ text: String, color: Color) -> some View {
    Text(text).foregroundStyle(color)
  }

  private func customCard() -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(isCustom ? AppTheme.accent : AppTheme.textSecondary)

        VStack(alignment: .leading, spacing: 2) {
          Text("Custom")
            .font(.system(.subheadline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
          Text("Set your own calorie and macro targets")
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        if isCustom {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(AppTheme.accent)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { selectCustom() }

      if isCustom {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          Divider()

          Stepper(value: $dailyCalories, in: 1000...4500, step: 50) {
            HStack {
              Text("Calories")
                .font(AppTheme.Typography.settingsBody)
              Spacer()
              Text("\(dailyCalories)")
                .font(AppTheme.Typography.dataMedium)
                .foregroundStyle(AppTheme.accent)
            }
          }

          macroSlider(title: "Protein", value: $proteinPercent, color: AppTheme.macroProtein)
          macroSlider(title: "Carbs", value: $carbsPercent, color: AppTheme.macroCarbs)
          macroSlider(title: "Fat", value: $fatPercent, color: AppTheme.macroFat)

          HStack {
            Text("Total")
              .font(AppTheme.Typography.settingsBody)
            Spacer()
            Text("\(macroTotal)%")
              .font(AppTheme.Typography.dataMedium)
              .foregroundStyle(macroTotal == 100 ? AppTheme.sage : AppTheme.accent)
          }

          if macroTotal != 100 {
            Text("Adjust to reach 100% before saving.")
              .font(AppTheme.Typography.settingsCaption)
              .foregroundStyle(AppTheme.accent)
          }

          Button("Reset to recommended") {
            let split = HealthGoal.general.defaultMacroSplit
            proteinPercent = Int((split.protein * 100).rounded())
            carbsPercent = Int((split.carbs * 100).rounded())
            fatPercent = Int((split.fat * 100).rounded())
            dailyCalories = HealthGoal.general.suggestedCalories
          }
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.accent)
        }
        .transition(customControlsTransition)
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(isCustom ? AppTheme.accent.opacity(0.06) : AppTheme.surfaceElevated)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(
          isCustom ? AppTheme.accent : AppTheme.oat.opacity(0.22), lineWidth: isCustom ? 2 : 1)
    )
  }

  private func macroSlider(title: String, value: Binding<Int>, color: Color) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack {
        Text(title)
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Text("\(value.wrappedValue)%")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(color)
      }

      Slider(
        value: Binding(
          get: { Double(value.wrappedValue) },
          set: { value.wrappedValue = Int($0.rounded()) }
        ),
        in: 10...70,
        step: 1
      )
      .tint(color)
    }
  }

  private func selectPreset(_ goal: HealthGoal) {
    withAnimation(reduceMotion ? AppMotion.colorTransition : AppMotion.settingsDisclosureCollapse) {
      selectedPreset = goal
      dailyCalories = goal.suggestedCalories
      let split = goal.defaultMacroSplit
      proteinPercent = Int((split.protein * 100).rounded())
      carbsPercent = Int((split.carbs * 100).rounded())
      fatPercent = Int((split.fat * 100).rounded())
    }
    AppPreferencesStore.haptic(.light)
  }

  private func selectCustom() {
    withAnimation(reduceMotion ? AppMotion.colorTransition : AppMotion.settingsDisclosureExpand) {
      selectedPreset = nil
    }
    AppPreferencesStore.haptic(.light)
  }

  private func load() {
    profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    let goal = profile.goal
    dailyCalories = profile.dailyCalories ?? goal.suggestedCalories
    proteinPercent = Int((profile.proteinPct * 100).rounded())
    carbsPercent = Int((profile.carbsPct * 100).rounded())
    fatPercent = Int((profile.fatPct * 100).rounded())

    let defaultSplit = goal.defaultMacroSplit
    let matchesPreset =
      dailyCalories == goal.suggestedCalories
      && proteinPercent == Int((defaultSplit.protein * 100).rounded())
      && carbsPercent == Int((defaultSplit.carbs * 100).rounded())
      && fatPercent == Int((defaultSplit.fat * 100).rounded())

    selectedPreset = matchesPreset ? goal : nil
  }

  private func save() {
    guard saveEnabled else {
      validationMessage = "Macro percentages must total 100%."
      return
    }

    validationMessage = nil
    profile.goal = selectedPreset ?? .general
    profile.dailyCalories = dailyCalories
    profile.proteinPct = Double(proteinPercent) / 100
    profile.carbsPct = Double(carbsPercent) / 100
    profile.fatPct = Double(fatPercent) / 100

    do {
      try deps.userDataRepository.saveHealthProfile(profile)
      AppPreferencesStore.notification(.success)
      onSaved()
      dismiss()
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

private struct NutritionDisclosurePhaseModifier: ViewModifier {
  let opacity: Double
  let verticalScale: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .scaleEffect(x: 1, y: verticalScale, anchor: .top)
      .clipped()
  }
}

extension AnyTransition {
  fileprivate static var nutritionCustomControls: AnyTransition {
    .asymmetric(
      insertion: .modifier(
        active: NutritionDisclosurePhaseModifier(opacity: 0, verticalScale: 0.965),
        identity: NutritionDisclosurePhaseModifier(opacity: 1, verticalScale: 1)
      ),
      removal: .modifier(
        active: NutritionDisclosurePhaseModifier(opacity: 0, verticalScale: 0.985),
        identity: NutritionDisclosurePhaseModifier(opacity: 1, verticalScale: 1)
      )
    )
  }
}

// MARK: - Macro Split Bar

struct MacroSplitBar: View {
  let protein: Int
  let carbs: Int
  let fat: Int
  var height: CGFloat = 6

  private var total: Int { max(protein + carbs + fat, 1) }

  var body: some View {
    GeometryReader { geo in
      let gap: CGFloat = 2
      let available = geo.size.width - gap * 2
      let pW = available * CGFloat(protein) / CGFloat(total)
      let cW = available * CGFloat(carbs) / CGFloat(total)
      let fW = available * CGFloat(fat) / CGFloat(total)

      HStack(spacing: gap) {
        Capsule().fill(AppTheme.macroProtein).frame(width: max(pW, 2))
        Capsule().fill(AppTheme.macroCarbs).frame(width: max(cW, 2))
        Capsule().fill(AppTheme.macroFat).frame(width: max(fW, 2))
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}
