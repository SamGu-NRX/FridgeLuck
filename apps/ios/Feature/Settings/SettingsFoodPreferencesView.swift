import SwiftUI

struct SettingsFoodPreferencesView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = HealthProfile.default
  @State private var selectedDiet: SettingsDietOption = .classic
  @State private var selectedAllergenIDs: Set<Int64> = []
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

        Button(action: save) {
          Text("Save")
            .font(AppTheme.Typography.settingsBodySemibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Space.sm)
            .background(Capsule().fill(AppTheme.accent))
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.xs)
      }
      .padding(.vertical, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Home.navOrbLift)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
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

  private func load() async {
    profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    selectedDiet = SettingsDietOption(profile: profile)
    selectedAllergenIDs = Set(profile.parsedAllergenIds)
    allergenCatalog = await OnboardingAllergenCatalogLoader.load(from: deps.ingredientRepository)
  }

  private func save() {
    validationMessage = nil
    profile.dietaryRestrictions = (try? encodeJSON(selectedDiet.storedRestrictions)) ?? "[]"
    profile.allergenIngredientIds = (try? encodeJSON(Array(selectedAllergenIDs).sorted())) ?? "[]"

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
