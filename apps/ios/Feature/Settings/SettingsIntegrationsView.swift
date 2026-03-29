import SwiftUI

struct SettingsIntegrationsView: View {
  @EnvironmentObject private var deps: AppDependencies

  let refreshID: Int
  let onRequestAppleHealth: () -> Void

  @State private var appleHealthStatus: AppPermissionStatus = .notDetermined

  var body: some View {
    Form {
      Section {
        FLSettingsStatusRow(
          title: "Nutrition sync",
          status: appleHealthStatus.settingsLabel,
          detail: appleHealthStatus.settingsDetail,
          badge: appleHealthStatus.settingsBadge
        )

        if let actionTitle {
          Button(actionTitle) {
            handleAction()
          }
        }
      } header: {
        Text("Apple Health")
      } footer: {
        FLSettingsFootnote(
          text:
            "FridgeLuck can read nutrition totals and write completed meal logs only when you allow access."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Integrations")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground(renderMode: .interactive)
    .task(id: refreshID) {
      load()
    }
  }

  private var actionTitle: String? {
    switch appleHealthStatus {
    case .authorized, .limited, .unavailable:
      return nil
    case .notDetermined:
      return "Connect Apple Health"
    case .denied, .restricted:
      return "Open iOS Settings"
    }
  }

  private func load() {
    appleHealthStatus = deps.appleHealthService.authorizationStatus()
  }

  private func handleAction() {
    switch appleHealthStatus {
    case .notDetermined:
      onRequestAppleHealth()
    case .denied, .restricted:
      AppPermissionCenter.openAppSettings()
    case .authorized, .limited, .unavailable:
      break
    }
  }
}
