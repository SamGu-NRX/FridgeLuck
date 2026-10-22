import SwiftUI

struct SettingsProfileBasicsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var loadState: HealthProfileLoad = .loading
  @State private var displayName = ""
  @State private var ageText = ""
  @State private var validationMessage: String?

  var body: some View {
    Form {
      if loadState.isFailed {
        Section {
          FLEmptyState(
            title: "Couldn't load your profile",
            message: "Your saved name and age are unchanged.",
            systemImage: "exclamationmark.triangle.fill",
            actionTitle: "Retry",
            action: load
          )
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      } else {
        profileFields
      }
    }
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Profile Basics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          save()
        }
        .disabled(loadState.profile == nil)
      }
    }
    .flPageBackground(renderMode: .interactive)
    .task {
      load()
    }
  }

  private var profileFields: some View {
    Section {
      TextField("Display name", text: $displayName)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()

      TextField("Age", text: $ageText)
        .keyboardType(.numberPad)
    } footer: {
      if let validationMessage {
        Text(validationMessage)
          .font(AppTheme.Typography.settingsCaption)
          .foregroundStyle(AppTheme.accent)
      } else {
        FLSettingsFootnote(
          text: "Name and age personalize your recipe recommendations."
        )
      }
    }
  }

  private var parsedAge: Int? {
    guard !ageText.isEmpty else { return nil }
    return Int(ageText)
  }

  private func load() {
    loadState = .read { try deps.userDataRepository.fetchHealthProfile() }
    guard let profile = loadState.profile else { return }
    displayName = profile.displayName
    ageText = profile.age.map(String.init) ?? ""
  }

  private func save() {
    if let parsedAge, !(13...100).contains(parsedAge) {
      validationMessage = "Age must be between 13 and 100."
      return
    }

    validationMessage = nil
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let age = parsedAge

    do {
      try loadState.save({ profile in
        profile.displayName = name
        profile.age = age
      }, writing: deps.userDataRepository.saveHealthProfile)
      AppPreferencesStore.notification(.success)
      onSaved()
      dismiss()
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}
