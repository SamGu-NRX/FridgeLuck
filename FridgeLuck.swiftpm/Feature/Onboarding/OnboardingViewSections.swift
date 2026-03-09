import SwiftUI

// MARK: - Shared Types

struct DietOption: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let icon: FLIcon
}

private enum OnboardingTypography {
  static let sectionTitle = Font.system(.title, design: .serif, weight: .bold)
  static let welcomeTitle = Font.system(.largeTitle, design: .serif, weight: .bold)
}

// MARK: - Progress Bar

struct OnboardingProgressBar: View {
  let progress: Double
  let reduceMotion: Bool

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(AppTheme.oat.opacity(0.18))
          .frame(height: 4)

        Capsule()
          .fill(AppTheme.accent)
          .frame(width: geo.size.width * max(0, min(1, progress)), height: 4)
          .animation(reduceMotion ? nil : AppMotion.progressBar, value: progress)
      }
    }
    .frame(height: 4)
    .padding(.horizontal, AppTheme.Space.page)
  }
}

// MARK: - Back Button

struct OnboardingBackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(AppTheme.textSecondary)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Step 1: Name Input

struct OnboardingNameStep: View {
  @Binding var displayName: String
  @FocusState.Binding var isNameFocused: Bool
  let validationMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 80)

      VStack(spacing: AppTheme.Space.lg) {
        Text("What's your name?")
          .font(OnboardingTypography.sectionTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text("We'll use this to personalize your experience.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)

        TextField("Your name", text: $displayName)
          .font(.system(size: 24, weight: .medium, design: .serif))
          .multilineTextAlignment(.center)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .focused($isNameFocused)
          .padding(.vertical, AppTheme.Space.md)
          .background(
            VStack {
              Spacer()
              Rectangle()
                .fill(AppTheme.accent.opacity(0.35))
                .frame(height: 2)
            }
          )
          .padding(.horizontal, AppTheme.Space.xl)

        if let validationMessage {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(validationMessage)
          }
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.warning)
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }
}

// MARK: - Step 2: Welcome

struct OnboardingWelcomeStep: View {
  let displayName: String

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 100)

      VStack(spacing: AppTheme.Space.lg) {
        Text("Welcome, \(displayName)!")
          .font(OnboardingTypography.welcomeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        VStack(spacing: AppTheme.Space.md) {
          Text("Let's set up your kitchen profile so\nFridgeLuck can work its magic.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: AppTheme.Space.md) {
            welcomeFeature(icon: "fork.knife", text: "Personalized recipes")
            welcomeFeature(icon: "shield.lefthalf.filled", text: "Allergen safety")
            welcomeFeature(icon: "chart.bar", text: "Nutrition tracking")
          }
          .padding(.top, AppTheme.Space.md)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }

  private func welcomeFeature(icon: String, text: String) -> some View {
    VStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(AppTheme.accent)
        .frame(width: 48, height: 48)
        .background(AppTheme.accent.opacity(0.10), in: Circle())

      Text(text)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Step 3: Age (Horizontal Scroll Ruler)

struct OnboardingAgeStep: View {
  @Binding var age: Int
  let reduceMotion: Bool

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 60)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("How old are you?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("This helps us tailor nutrition recommendations.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.sm) {
          Text("\(age)")
            .font(.system(size: 64, weight: .bold, design: .serif))
            .foregroundStyle(AppTheme.textPrimary)
            .contentTransition(.numericText(value: Double(age)))
            .animation(reduceMotion ? nil : AppMotion.rulerSnap, value: age)

          Text("years old")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }

        HorizontalScrollRuler(
          value: $age,
          range: 13...100,
          reduceMotion: reduceMotion
        )
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }
}

// MARK: - Horizontal Scroll Ruler

struct HorizontalScrollRuler: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let reduceMotion: Bool

  @State private var dragOffset: CGFloat = 0
  @State private var baseValue: Int = 0
  @GestureState private var isDragging = false

  private let tickSpacing: CGFloat = 12
  private let majorTickInterval = 5

  var body: some View {
    GeometryReader { geo in
      let center = geo.size.width / 2

      ZStack {
        Canvas { context, size in
          let totalTicks = range.upperBound - range.lowerBound
          let centerY = size.height / 2

          for i in 0...totalTicks {
            let tickValue = range.lowerBound + i
            let xOffset = CGFloat(tickValue - value) * tickSpacing + dragOffset + center
            guard xOffset > -tickSpacing, xOffset < size.width + tickSpacing else { continue }

            let isMajor = (tickValue % majorTickInterval) == 0
            let distFromCenter = abs(xOffset - center)
            let fadeAlpha = max(0, 1.0 - distFromCenter / (size.width * 0.48))

            let tickHeight: CGFloat = isMajor ? 28 : 14
            let tickWidth: CGFloat = isMajor ? 2 : 1
            let tickColor: Color = isMajor ? AppTheme.textPrimary : AppTheme.oat

            let rect = CGRect(
              x: xOffset - tickWidth / 2,
              y: centerY - tickHeight / 2,
              width: tickWidth,
              height: tickHeight
            )
            context.opacity = fadeAlpha
            context.fill(
              Path(roundedRect: rect, cornerRadius: tickWidth / 2),
              with: .color(tickColor)
            )

            if isMajor {
              let text = Text("\(tickValue)")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
              context.draw(
                context.resolve(text),
                at: CGPoint(x: xOffset, y: centerY + tickHeight / 2 + 12)
              )
            }
          }
        }

        VStack(spacing: 0) {
          RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.accent)
            .frame(width: 3, height: 36)
        }
        .position(x: center, y: geo.size.height / 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($isDragging) { _, state, _ in state = true }
          .onChanged { gesture in
            dragOffset = gesture.translation.width
            setValue(for: gesture.translation.width, from: baseValue)
          }
          .onEnded { gesture in
            let finalValue = resolvedValue(for: gesture.translation.width, from: baseValue)
            value = finalValue
            baseValue = finalValue
            if reduceMotion {
              dragOffset = 0
            } else {
              withAnimation(AppMotion.rulerSnap) {
                dragOffset = 0
              }
            }
          }
      )
      .onChange(of: isDragging) { _, dragging in
        if dragging {
          baseValue = value
          dragOffset = 0
        }
      }
    }
    .frame(height: 72)
    .clipped()
    .onAppear {
      baseValue = value
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Age")
    .accessibilityValue("\(value) years old")
    .accessibilityHint("Swipe up or down with one finger to adjust.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        step(by: 1)
      case .decrement:
        step(by: -1)
      @unknown default:
        break
      }
    }
  }

  private func resolvedValue(for translationWidth: CGFloat, from baseValue: Int) -> Int {
    let rawValue = Double(baseValue) + Double(-translationWidth) / Double(tickSpacing)
    return clampedValue(Int(rawValue.rounded()))
  }

  private func setValue(for translationWidth: CGFloat, from baseValue: Int) {
    let nextValue = resolvedValue(for: translationWidth, from: baseValue)
    if nextValue != value {
      value = nextValue
    }
  }

  private func step(by delta: Int) {
    let nextValue = clampedValue(value + delta)
    guard nextValue != value else { return }
    value = nextValue
    baseValue = nextValue
  }

  private func clampedValue(_ candidate: Int) -> Int {
    min(max(candidate, range.lowerBound), range.upperBound)
  }
}

// MARK: - Step 4: Goal Selection

struct OnboardingGoalStep: View {
  @Binding var goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct GoalOption: Identifiable {
    let id: HealthGoal
    let icon: String
    let description: String
    let accent: Color
  }

  private let options: [GoalOption] = [
    .init(
      id: .general, icon: "heart", description: "Balanced nutrition for everyday wellness",
      accent: AppTheme.sage),
    .init(
      id: .weightLoss, icon: "flame", description: "Lower calorie target to support weight loss",
      accent: AppTheme.accent),
    .init(
      id: .muscleGain, icon: "dumbbell",
      description: "Higher protein and calories for muscle growth", accent: AppTheme.oat),
    .init(
      id: .maintenance, icon: "scale.3d", description: "Maintain your current weight and energy",
      accent: AppTheme.dustyRose),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("What's your goal?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Pick your primary nutrition direction.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(options) { option in
            goalCard(option)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func goalCard(_ option: GoalOption) -> some View {
    let selected = goal == option.id

    return Button {
      goal = option.id
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        Image(systemName: option.icon)
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(selected ? option.accent : AppTheme.textSecondary)
          .frame(width: 44, height: 44)
          .background(
            (selected ? option.accent : AppTheme.oat).opacity(selected ? 0.15 : 0.10),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          )

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(option.id.displayName)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)

          Text(option.description)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(2)
        }

        Spacer(minLength: 0)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? option.accent : AppTheme.oat.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        selected ? option.accent.opacity(0.08) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(
            selected ? option.accent.opacity(0.40) : AppTheme.oat.opacity(0.25),
            lineWidth: selected ? 1.5 : 1
          )
      )
      .shadow(
        color: selected ? option.accent.opacity(0.12) : AppTheme.Shadow.color,
        radius: selected ? 10 : 4,
        x: 0,
        y: selected ? 4 : 2
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .animation(reduceMotion ? nil : AppMotion.selectionPress, value: selected)
  }
}

// MARK: - Step 5: Daily Calorie Target

struct OnboardingCalorieStep: View {
  @Binding var dailyCalories: Int
  let goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 60)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("Daily calorie target")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Adjust to match your lifestyle. We've pre-filled based on your goal.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.md) {
          HStack(spacing: AppTheme.Space.sm) {
            Button {
              dailyCalories = max(1000, dailyCalories - 50)
            } label: {
              Image(systemName: "minus")
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
                .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(.plain)

            Text("\(dailyCalories)")
              .font(.system(size: 56, weight: .bold, design: .serif))
              .foregroundStyle(AppTheme.textPrimary)
              .frame(maxWidth: .infinity)
              .contentTransition(.numericText(value: Double(dailyCalories)))
              .animation(reduceMotion ? nil : AppMotion.quick, value: dailyCalories)

            Button {
              dailyCalories = min(4500, dailyCalories + 50)
            } label: {
              Image(systemName: "plus")
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
                .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(.plain)
          }

          Text("kcal / day")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)

          Slider(
            value: Binding(
              get: { Double(dailyCalories) },
              set: { dailyCalories = Int($0.rounded()) }
            ),
            in: 1000...4500,
            step: 50
          )
          .tint(AppTheme.accent)
          .padding(.horizontal, AppTheme.Space.sm)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }
}

// MARK: - Step 6: Diet Selection (Single-select)

struct OnboardingDietStep: View {
  let options: [DietOption]
  let selectedDiet: String
  let onSelect: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("Do you follow a\nspecific diet?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("This helps us recommend the right recipes.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(options) { option in
            dietRow(option)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func dietRow(_ option: DietOption) -> some View {
    let selected = selectedDiet == option.id

    return Button {
      onSelect(option.id)
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        FLIconView(option.icon, size: 22)
          .foregroundStyle(selected ? AppTheme.accent : AppTheme.textSecondary)
          .frame(width: 44, height: 44)
          .background(
            (selected ? AppTheme.accent : AppTheme.oat).opacity(selected ? 0.15 : 0.10),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          )

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(option.title)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)

          Text(option.subtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? AppTheme.accent : AppTheme.oat.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        selected ? AppTheme.accent.opacity(0.08) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(
            selected ? AppTheme.accent.opacity(0.40) : AppTheme.oat.opacity(0.25),
            lineWidth: selected ? 1.5 : 1
          )
      )
      .shadow(
        color: selected ? AppTheme.accent.opacity(0.12) : AppTheme.Shadow.color,
        radius: selected ? 10 : 4,
        x: 0,
        y: selected ? 4 : 2
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .animation(reduceMotion ? nil : AppMotion.selectionPress, value: selected)
  }
}

// MARK: - Step 7: Allergen Safety

struct OnboardingAllergenStep: View {
  let allergenGroupMatchesByID: [String: Set<Int64>]
  let selectedAllergens: Set<Int64>
  let selectedAllergenIngredients: [Ingredient]
  let onToggleGroup: (AllergenGroupDefinition) -> Void
  let onOpenPicker: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectedAllergenChipNamespace

  private enum Layout {
    static let allergenGroupChipHeight: CGFloat = 92
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .center, spacing: AppTheme.Space.xs) {
          Text("Allergen safety")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

          Text(
            "Start with the Big 10 here. Open the detail picker only if you want exact ingredient-level control."
          )
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
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

        Button(action: onOpenPicker) {
          Label("Refine Specific Ingredients", systemImage: "magnifyingglass")
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
                  .matchedGeometryEffect(
                    id: ingredient.id ?? Int64.min,
                    in: selectedAllergenChipNamespace,
                    properties: .frame
                  )
              }
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func allergenGroupChip(_ group: AllergenGroupDefinition) -> some View {
    let matchedIDs = allergenGroupMatchesByID[group.id] ?? []
    let selectedCount = selectedAllergens.intersection(matchedIDs).count
    let isFullySelected = !matchedIDs.isEmpty && selectedCount == matchedIDs.count
    let isPartiallySelected = selectedCount > 0 && !isFullySelected
    let isSelected = isFullySelected || isPartiallySelected

    return Button {
      onToggleGroup(group)
    } label: {
      HStack(spacing: AppTheme.Space.xs) {
        FLIconView(group.icon.source, size: 22)
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
        maxWidth: .infinity,
        minHeight: Layout.allergenGroupChipHeight,
        maxHeight: Layout.allergenGroupChipHeight,
        alignment: .leading
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
}

// MARK: - Onboarding Footer (Continue Button)

struct OnboardingFooter: View {
  let isSaving: Bool
  let isTransitioning: Bool
  let primaryButtonTitle: String
  let primaryButtonIcon: String
  let onPrimaryAction: () -> Void

  var body: some View {
    VStack(spacing: AppTheme.Space.xs) {
      FLPrimaryButton(
        primaryButtonTitle,
        systemImage: primaryButtonIcon,
        isEnabled: !isSaving && !isTransitioning,
        labelAnimation: .subtleBlend
      ) {
        onPrimaryAction()
      }
      .buttonRepeatBehavior(.disabled)

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
}
