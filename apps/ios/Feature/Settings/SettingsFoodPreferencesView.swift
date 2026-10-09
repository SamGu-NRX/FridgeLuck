import SwiftUI

struct SettingsFoodPreferencesView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = HealthProfile.default
  @State private var selectedDiet: SettingsDietOption = .classic
  @State private var selectedAllergenIDs: Set<Int64> = []
  // Explicit allergen group selection — persisted as-is, never derived from
  // selectedAllergenIDs.
  @State private var selectedAllergenGroups: Set<String> = []
  @State private var confirmedNoGroups = false
  @State private var loadedPreferencesVersion = 0
  @State private var allergenCatalog: AllergenCatalogIndex = .empty
  @State private var showAllergenPicker = false
  @State private var validationMessage: String?
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Diet style")
          .font(.system(.subheadline, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        VStack(spacing: AppTheme.Space.xs) {
          ForEach(SettingsDietOption.allCases) { option in
            dietCard(option)
              .onTapGesture {
                withAnimation(AppMotion.standard) { selectedDiet = option }
                AppPreferencesStore.haptic(.light)
              }
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        Text("Allergen filters")
          .font(.system(.subheadline, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          if loadedPreferencesVersion < AllergenExclusions.currentPreferencesVersion {
            Label(
              "Please confirm your allergen groups below — your flagged ingredients are kept.",
              systemImage: "arrow.triangle.2.circlepath"
            )
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, AppTheme.Space.xxs)
          }

          LazyVGrid(
            columns: [
              GridItem(.flexible(), spacing: AppTheme.Space.xs),
              GridItem(.flexible(), spacing: AppTheme.Space.xs),
            ],
            spacing: AppTheme.Space.xs
          ) {
            ForEach(AllergenSupport.groups) { group in
              groupChip(group)
            }
          }

          Button {
            withAnimation(reduceMotion ? nil : AppMotion.standard) {
              selectedAllergenGroups = []
              confirmedNoGroups = true
            }
            AppPreferencesStore.haptic(.light)
          } label: {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: confirmedNoGroups ? "checkmark.circle.fill" : "circle")
              Text("I have no allergen groups to flag")
                .font(AppTheme.Typography.settingsBody)
            }
            .foregroundStyle(confirmedNoGroups ? AppTheme.sage : AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Space.md)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(confirmedNoGroups ? AppTheme.sage.opacity(0.12) : AppTheme.surfaceElevated)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(
                  confirmedNoGroups ? AppTheme.sage : AppTheme.oat.opacity(0.22),
                  lineWidth: 1)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(confirmedNoGroups ? .isSelected : [])

          Button {
            showAllergenPicker = true
          } label: {
            HStack {
              Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.accent)

              VStack(alignment: .leading, spacing: 2) {
                Text("Refine ingredients")
                  .font(AppTheme.Typography.settingsBody)
                  .foregroundStyle(AppTheme.textPrimary)
                Text(
                  selectedAllergenIDs.isEmpty
                    ? "No filters applied"
                    : "\(selectedAllergenIDs.count) ingredient\(selectedAllergenIDs.count == 1 ? "" : "s") excluded"
                )
                .font(AppTheme.Typography.settingsCaption)
                .foregroundStyle(AppTheme.textSecondary)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
            }
            .padding(AppTheme.Space.md)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.surfaceElevated)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
            )
          }
          .buttonStyle(.plain)

          if !selectedIngredients.isEmpty {
            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(Array(selectedIngredients.prefix(10)), id: \.id) { ingredient in
                FLSettingsBadgeView(
                  badge: FLSettingsBadge(text: ingredient.displayName, tone: .accent)
                )
              }
            }
            .padding(.horizontal, AppTheme.Space.xxs)
          }
        }
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
      FLPrimaryButton("Save", action: save)
    }
    .navigationTitle("Food Preferences")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task { await load() }
    .sheet(isPresented: $showAllergenPicker) {
      AllergenPickerView(catalog: allergenCatalog, selectedIDs: $selectedAllergenIDs)
    }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  private func dietCard(_ option: SettingsDietOption) -> some View {
    let isSelected = selectedDiet == option

    return HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: option.icon)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(option.title)
          .font(AppTheme.Typography.settingsBody)
          .foregroundStyle(AppTheme.textPrimary)
        Text(option.shortDescription)
          .font(AppTheme.Typography.settingsCaption)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()

      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(AppTheme.accent)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .padding(AppTheme.Space.md)
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
    .accessibilityLabel("\(option.title), \(option.shortDescription)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var selectedIngredients: [Ingredient] {
    allergenCatalog.selectedIngredients(from: selectedAllergenIDs)
  }

  private func groupChip(_ group: AllergenGroupDefinition) -> some View {
    let isSelected = selectedAllergenGroups.contains(group.id)

    return Button {
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        if isSelected {
          selectedAllergenGroups.remove(group.id)
        } else {
          selectedAllergenGroups.insert(group.id)
          confirmedNoGroups = false
        }
      }
      AppPreferencesStore.haptic(.light)
    } label: {
      HStack(spacing: AppTheme.Space.xxs) {
        FLIconView(group.icon.source, size: 18)
        Text(group.title)
          .font(AppTheme.Typography.settingsCaption)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      }
      .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textPrimary)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.sm)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .fill(isSelected ? AppTheme.accent.opacity(0.10) : AppTheme.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.22), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func load() async {
    profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    selectedDiet = SettingsDietOption(profile: profile)
    selectedAllergenIDs = Set(profile.parsedAllergenIds)
    selectedAllergenGroups = profile.parsedAllergenSelectedGroups
    loadedPreferencesVersion = profile.allergenPreferencesVersion
    confirmedNoGroups =
      selectedAllergenGroups.isEmpty && !profile.allergenNeedsGroupConfirmation
    allergenCatalog = await OnboardingAllergenCatalogLoader.load(from: deps.ingredientRepository)
  }

  private func save() {
    validationMessage = nil

    // Explicit confirmation is required to record "no allergen groups": an untouched
    // selection is never silently read as "no allergies".
    if selectedAllergenGroups.isEmpty && !confirmedNoGroups {
      validationMessage =
        "Choose the allergen groups to avoid, or confirm you have none to flag."
      return
    }

    profile.dietaryRestrictions = (try? encodeJSON(selectedDiet.storedRestrictions)) ?? "[]"
    profile.allergenIngredientIds = (try? encodeJSON(Array(selectedAllergenIDs).sorted())) ?? "[]"
    profile.allergenSelectedGroups =
      (try? encodeJSON(Array(selectedAllergenGroups).sorted())) ?? "[]"
    profile.allergenPreferencesVersion = AllergenExclusions.currentPreferencesVersion

    do {
      try deps.userDataRepository.saveHealthProfile(profile)
      AppPreferencesStore.notification(.success)
      onSaved()
      dismiss()
    } catch {
      validationMessage = error.localizedDescription
    }
  }

  private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw CocoaError(.coderInvalidValue)
    }
    return json
  }
}
