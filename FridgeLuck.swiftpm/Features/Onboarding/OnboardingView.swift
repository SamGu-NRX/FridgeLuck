import SwiftUI

/// Health onboarding and profile editor.
struct OnboardingView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  let isRequired: Bool
  let onComplete: () -> Void

  @State private var goal: HealthGoal = .general
  @State private var dailyCalories: Int = HealthGoal.general.suggestedCalories
  @State private var selectedRestrictions: Set<String> = []
  @State private var selectedAllergens: Set<Int64> = []
  @State private var allIngredients: [Ingredient] = []

  @State private var isLoaded = false
  @State private var isSaving = false
  @State private var errorMessage: String?

  private let restrictionOptions: [(id: String, title: String)] = [
    ("vegetarian", "Vegetarian"),
    ("vegan", "Vegan"),
    ("gluten_free", "Gluten Free"),
    ("dairy_free", "Dairy Free"),
    ("low_carb", "Low Carb"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            isRequired
              ? "Set your health profile to personalize recommendations."
              : "Update your health preferences."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }

        Section("Goal") {
          Picker("Health Goal", selection: $goal) {
            ForEach(HealthGoal.allCases, id: \.self) { value in
              Text(value.displayName).tag(value)
            }
          }
          .onChange(of: goal) { oldGoal, newGoal in
            if !isLoaded || dailyCalories == 0 || dailyCalories == oldGoal.suggestedCalories {
              dailyCalories = newGoal.suggestedCalories
            }
          }

          Stepper(value: $dailyCalories, in: 1000...4500, step: 50) {
            Text("Daily Calories: \(dailyCalories)")
          }
        }

        Section("Dietary Restrictions") {
          ForEach(restrictionOptions, id: \.id) { option in
            Toggle(
              option.title,
              isOn: Binding(
                get: { selectedRestrictions.contains(option.id) },
                set: { enabled in
                  if enabled {
                    selectedRestrictions.insert(option.id)
                  } else {
                    selectedRestrictions.remove(option.id)
                  }
                }
              )
            )
          }
        }

        Section("Allergens") {
          NavigationLink {
            AllergenSelectionView(
              allIngredients: allIngredients,
              selectedAllergens: $selectedAllergens
            )
          } label: {
            HStack {
              Text("Select Allergens")
              Spacer()
              Text("\(selectedAllergens.count)")
                .foregroundStyle(.secondary)
            }
          }
        }

        Section {
          Button {
            saveProfile()
          } label: {
            HStack {
              Spacer()
              if isSaving {
                ProgressView()
              } else {
                Text(isRequired ? "Continue" : "Save Profile")
              }
              Spacer()
            }
          }
          .disabled(isSaving)
        }
      }
      .navigationTitle(isRequired ? "Welcome to FridgeLuck" : "Health Profile")
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
          set: { show in
            if !show { errorMessage = nil }
          }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
      .task {
        guard !isLoaded else { return }
        isLoaded = true
        await loadProfile()
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
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to serialize profile values."
        ])
    }
    return string
  }
}

private struct AllergenSelectionView: View {
  let allIngredients: [Ingredient]
  @Binding var selectedAllergens: Set<Int64>
  @State private var searchText = ""

  private var filtered: [Ingredient] {
    if searchText.isEmpty {
      return allIngredients
    }
    let lowered = searchText.lowercased()
    return allIngredients.filter { ingredient in
      ingredient.name.lowercased().contains(lowered)
    }
  }

  var body: some View {
    List(filtered, id: \.id) { ingredient in
      if let id = ingredient.id {
        Button {
          if selectedAllergens.contains(id) {
            selectedAllergens.remove(id)
          } else {
            selectedAllergens.insert(id)
          }
        } label: {
          HStack {
            Text(ingredient.name.replacingOccurrences(of: "_", with: " ").capitalized)
            Spacer()
            if selectedAllergens.contains(id) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }
        .foregroundStyle(.primary)
      }
    }
    .searchable(text: $searchText, prompt: "Search ingredients")
    .navigationTitle("Allergens")
    .navigationBarTitleDisplayMode(.inline)
  }
}
