import SwiftUI

struct SettingsNutritionTargetsView: View {
  private static let fallbackProfile = HealthProfile.default

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = Self.fallbackProfile
  @State private var goal: HealthGoal = Self.fallbackProfile.goal
  @State private var dailyCalories =
    Self.fallbackProfile.dailyCalories ?? Self.fallbackProfile.goal.suggestedCalories
  @State private var proteinPercent = Int((Self.fallbackProfile.proteinPct * 100).rounded())
  @State private var carbsPercent = Int((Self.fallbackProfile.carbsPct * 100).rounded())
  @State private var fatPercent = Int((Self.fallbackProfile.fatPct * 100).rounded())
  @State private var validationMessage: String?

  var body: some View {
    Form {
      Section {
        Picker("Goal", selection: $goal) {
          ForEach(HealthGoal.allCases, id: \.self) { option in
            Text(option.displayName).tag(option)
          }
        }

        Stepper(value: $dailyCalories, in: 1000...4500, step: 50) {
          HStack {
            Text("Daily calories")
            Spacer()
            Text("\(dailyCalories)")
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      } header: {
        Text("Goal")
      } footer: {
        FLSettingsFootnote(
          text:
            "Start with the goal preset, then tune calories if you want a stricter or looser target."
        )
      }

      Section {
        Stepper(value: $proteinPercent, in: 10...70) {
          macroRow(title: "Protein", value: proteinPercent)
        }
        Stepper(value: $carbsPercent, in: 10...70) {
          macroRow(title: "Carbs", value: carbsPercent)
        }
        Stepper(value: $fatPercent, in: 10...70) {
          macroRow(title: "Fat", value: fatPercent)
        }

        HStack {
          Text("Total")
          Spacer()
          Text("\(macroTotal)%")
            .foregroundStyle(macroTotal == 100 ? AppTheme.textSecondary : AppTheme.accent)
        }

        Button("Reset to goal recommendation") {
          apply(goal.defaultMacroSplit)
        }
      } header: {
        Text("Macro Split")
      } footer: {
        FLSettingsFootnote(
          text: macroTotal == 100
            ? "Your split adds to 100%, so it is ready to save."
            : "Macro percentages must total 100% before you can save."
        )
      }

      if let validationMessage {
        Section {
          FLSettingsFootnote(text: validationMessage)
            .foregroundStyle(AppTheme.accent)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Nutrition Targets")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          save()
        }
        .disabled(macroTotal != 100)
      }
    }
    .flPageBackground(renderMode: .interactive)
    .task {
      load()
    }
    .onChange(of: goal) { _, newGoal in
      if profile.goal != newGoal {
        dailyCalories =
          profile.dailyCalories == profile.goal.suggestedCalories
          ? newGoal.suggestedCalories
          : dailyCalories
      }
    }
  }

  private var macroTotal: Int {
    proteinPercent + carbsPercent + fatPercent
  }

  @ViewBuilder
  private func macroRow(title: String, value: Int) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text("\(value)%")
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private func load() {
    profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    goal = profile.goal
    dailyCalories = profile.dailyCalories ?? profile.goal.suggestedCalories
    proteinPercent = Int((profile.proteinPct * 100).rounded())
    carbsPercent = Int((profile.carbsPct * 100).rounded())
    fatPercent = Int((profile.fatPct * 100).rounded())
  }

  private func apply(_ split: (protein: Double, carbs: Double, fat: Double)) {
    proteinPercent = Int((split.protein * 100).rounded())
    carbsPercent = Int((split.carbs * 100).rounded())
    fatPercent = Int((split.fat * 100).rounded())
  }

  private func save() {
    guard macroTotal == 100 else {
      validationMessage = "Macro percentages must total 100%."
      return
    }

    validationMessage = nil
    profile.goal = goal
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
