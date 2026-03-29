import SwiftUI

struct SettingsFoodPreferencesView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = HealthProfile.default
  @State private var selectedDiet: SettingsDietOption = .classic
  @State private var selectedAllergenIDs: Set<Int64> = []
  @State private var allergenCatalog: AllergenCatalogIndex = .empty
  @State private var showAllergenPicker = false
  @State private var validationMessage: String?

  var body: some View {
    Form {
      Section {
        Picker("Diet style", selection: $selectedDiet) {
          ForEach(SettingsDietOption.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } header: {
        Text("Diet")
      } footer: {
        FLSettingsFootnote(text: "Diet preferences steer recipe scoring and substitutions.")
      }

      Section("Allergen Filters") {
        Button {
          showAllergenPicker = true
        } label: {
          FLSettingsDisclosureRow(
            title: "Refine ingredients",
            value: selectedAllergenIDs.isEmpty
              ? "None selected" : "\(selectedAllergenIDs.count) selected",
            subtitle: "Use exact ingredients for finer control than the broad allergen groups."
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
          .padding(.vertical, AppTheme.Space.xxs)
        }
      }

      if let validationMessage {
        Section {
          FLSettingsFootnote(text: validationMessage)
            .foregroundStyle(AppTheme.accent)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Food Preferences")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          save()
        }
      }
    }
    .flPageBackground(renderMode: .interactive)
    .task {
      await load()
    }
    .sheet(isPresented: $showAllergenPicker) {
      AllergenPickerView(catalog: allergenCatalog, selectedIDs: $selectedAllergenIDs)
    }
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
