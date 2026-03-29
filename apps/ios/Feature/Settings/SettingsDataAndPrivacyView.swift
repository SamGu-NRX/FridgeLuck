import SwiftUI

struct SettingsDataAndPrivacyView: View {
  let onResetAllData: () -> Void

  @State private var showResetConfirmation = false

  var body: some View {
    Form {
      Section("Privacy") {
        FLSettingsFootnote(
          text:
            "Profile, cooking history, streaks, and tutorial progress are stored locally for the app experience. Apple Health access stays governed by iOS."
        )

        Button("Open iOS Settings") {
          AppPermissionCenter.openAppSettings()
        }
      }

      Section("About") {
        HStack {
          Text("App version")
          Spacer()
          Text(appVersion)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }

      Section {
        FLSettingsDestructiveGroup(
          title: "Reset FridgeLuck",
          message:
            "This clears your profile, cooking history, badges, streaks, and tutorial state. Bundled recipes and ingredients stay in place.",
          actionTitle: "Reset all user data"
        ) {
          showResetConfirmation = true
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Data & Privacy")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground(renderMode: .interactive)
    .alert("Reset FridgeLuck?", isPresented: $showResetConfirmation) {
      Button("Reset Everything", role: .destructive) {
        AppPreferencesStore.notification(.warning)
        onResetAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone.")
    }
  }

  private var appVersion: String {
    let shortVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(shortVersion) (\(buildNumber))"
  }
}
