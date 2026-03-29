import SwiftUI

struct SettingsProfileBasicsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var profile = HealthProfile.default
  @State private var displayName = ""
  @State private var ageText = ""
  @State private var validationMessage: String?

  var body: some View {
    Form {
      Section {
        TextField("Display name", text: $displayName)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()

        TextField("Age", text: $ageText)
          .keyboardType(.numberPad)
      } footer: {
        FLSettingsFootnote(
          text: "Name and age unlock personalized recipe guidance and mark onboarding complete."
        )
      }

      Section("Status") {
        FLSettingsStatusRow(
          title: "Profile completion",
          status: isProfileComplete ? "Ready" : "Incomplete",
          detail: isProfileComplete
            ? "Your profile has the minimum info needed for personalization."
            : "Set both a name and a valid age from 13 to 100.",
          badge: FLSettingsBadge(
            text: isProfileComplete ? "Complete" : "Needs attention",
            tone: isProfileComplete ? .positive : .warning
          )
        )

        if let validationMessage {
          FLSettingsFootnote(text: validationMessage)
            .foregroundStyle(AppTheme.accent)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Profile Basics")
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
      load()
    }
  }

  private var parsedAge: Int? {
    guard !ageText.isEmpty else { return nil }
    return Int(ageText)
  }

  private var isProfileComplete: Bool {
    let nameReady = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard let parsedAge else { return false }
    return nameReady && (13...100).contains(parsedAge)
  }

  private func load() {
    profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    displayName = profile.displayName
    ageText = profile.age.map(String.init) ?? ""
  }

  private func save() {
    if let parsedAge, !(13...100).contains(parsedAge) {
      validationMessage = "Age must be between 13 and 100."
      return
    }

    validationMessage = nil
    profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.age = parsedAge

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
