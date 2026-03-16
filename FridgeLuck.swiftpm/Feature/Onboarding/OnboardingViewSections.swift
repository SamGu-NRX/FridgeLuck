import SwiftUI

struct OnboardingRestrictionOption: Identifiable {
  let id: String
  let title: String
  let icon: String
}

struct OnboardingStepHeader: View {
  let stepIndex: Int
  let totalSteps: Int
  let title: String
  let subtitle: String
  let isRequired: Bool
  let reduceMotion: Bool

  private enum Layout {
    static let headerMinHeight: CGFloat = 156
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .center) {
        HStack(spacing: AppTheme.Space.sm) {
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
        Text(title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
        Text(subtitle)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, AppTheme.Space.sm)
    .frame(maxWidth: .infinity, minHeight: Layout.headerMinHeight, alignment: .topLeading)
  }
}

struct OnboardingGoalStepSection: View {
  @Binding var displayName: String
  @Binding var ageInput: String
  @Binding var goal: HealthGoal
  @Binding var dailyCalories: Int
  let identityValidationMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("YOUR PROFILE")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          TextField("Name", text: $displayName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(true)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.sm)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.surface)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
            )

          TextField("Age", text: $ageInput)
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.sm)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.surface)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
            )

          if let identityValidationMessage {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: "exclamationmark.circle.fill")
              Text(identityValidationMessage)
            }
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.warning)
          }
        }

        FLWaveDivider()
          .padding(.vertical, AppTheme.Space.sm)

        Text("Pick your primary nutrition direction")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("You can update this anytime from profile settings.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)

        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppTheme.Space.sm
        ) {
          goalCard(.general, accent: AppTheme.sage, rotation: -0.8)
          goalCard(.weightLoss, accent: AppTheme.accent, rotation: 1.0)
          goalCard(.muscleGain, accent: AppTheme.oat, rotation: 0.5)
          goalCard(.maintenance, accent: AppTheme.dustyRose, rotation: -1.2)
        }

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
}

struct OnboardingRestrictionStepSection: View {
  let options: [OnboardingRestrictionOption]
  let selectedRestrictions: Set<String>
  let onToggle: (String) -> Void

  var body: some View {
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
          ForEach(options) { option in
            restrictionOptionRow(option)
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

  private func restrictionOptionRow(_ option: OnboardingRestrictionOption) -> some View {
    let selected = selectedRestrictions.contains(option.id)

    return Button {
      onToggle(option.id)
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

struct OnboardingAllergenStepSection: View {
  let allergenGroupMatchesByID: [String: Set<Int64>]
  let selectedAllergens: Set<Int64>
  let selectedAllergenIngredients: [Ingredient]
  let onToggleGroup: (AllergenGroupDefinition) -> Void
  let onOpenPicker: () -> Void

  private enum Layout {
    static let allergenGroupChipHeight: CGFloat = 92
  }

  var body: some View {
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

        Button(action: onOpenPicker) {
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
    let matchedIDs = allergenGroupMatchesByID[group.id] ?? []
    let selectedCount = selectedAllergens.intersection(matchedIDs).count
    let isFullySelected = !matchedIDs.isEmpty && selectedCount == matchedIDs.count
    let isPartiallySelected = selectedCount > 0 && !isFullySelected
    let isSelected = isFullySelected || isPartiallySelected

    return Button {
      onToggleGroup(group)
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

struct OnboardingFooter: View {
  let stepIndex: Int
  let totalSteps: Int
  let isSaving: Bool
  let isTransitioning: Bool
  let reduceMotion: Bool
  let primaryButtonTitle: String
  let primaryButtonIcon: String
  let onBack: () -> Void
  let onPrimaryAction: () -> Void

  enum Layout {
    static let actionButtonHeight: CGFloat = 56
    static let allergenGroupChipHeight: CGFloat = 92
  }

  var body: some View {
    let backVisible = stepIndex > 0

    return VStack(spacing: AppTheme.Space.xs) {
      HStack(spacing: backVisible ? AppTheme.Space.sm : 0) {
        FLSecondaryButton("Back", systemImage: "chevron.left") {
          onBack()
        }
        .buttonRepeatBehavior(.disabled)
        .disabled(isSaving || isTransitioning)
        .frame(width: backVisible ? 132 : 0, height: Layout.actionButtonHeight)
        .opacity(backVisible ? 1 : 0)
        .clipped()
        .allowsHitTesting(backVisible)

        FLPrimaryButton(
          primaryButtonTitle,
          systemImage: primaryButtonIcon,
          isEnabled: !isSaving && !isTransitioning,
          labelAnimation: .subtleBlend
        ) {
          onPrimaryAction()
        }
        .buttonRepeatBehavior(.disabled)
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
}
