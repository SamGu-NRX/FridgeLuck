import SwiftUI

private struct SettingsPermissionItem: Identifiable {
  let id: AppPermission
  let title: String
}

struct SettingsPermissionsView: View {
  @State private var statuses: [AppPermission: AppPermissionStatus] = [:]

  private let items: [SettingsPermissionItem] = [
    SettingsPermissionItem(id: .camera, title: "Camera"),
    SettingsPermissionItem(id: .microphone, title: "Microphone"),
    SettingsPermissionItem(id: .photoLibraryReadWrite, title: "Photo Library"),
  ]

  var body: some View {
    Form {
      Section {
        ForEach(items) { item in
          permissionRow(for: item)
        }
      } header: {
        Text("Permissions")
      } footer: {
        FLSettingsFootnote(
          text:
            "Permissions stay off until you explicitly allow them. Denied permissions must be changed in iOS Settings."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Permissions")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground(renderMode: .interactive)
    .task {
      refreshStatuses()
    }
  }

  private func permissionRow(for item: SettingsPermissionItem) -> some View {
    let status = statuses[item.id] ?? .notDetermined

    return VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack(alignment: .center, spacing: AppTheme.Space.sm) {
        FLSettingsStatusRow(
          title: item.title,
          status: status.settingsLabel,
          detail: status.settingsDetail,
          badge: status.settingsBadge
        )

        Spacer(minLength: 0)
      }

      if let actionTitle = actionTitle(for: status) {
        Button(actionTitle) {
          handleAction(for: item.id, status: status)
        }
      }
    }
    .padding(.vertical, AppTheme.Space.xxs)
  }

  private func refreshStatuses() {
    statuses[.camera] = AppPermissionCenter.status(for: .camera)
    statuses[.microphone] = AppPermissionCenter.status(for: .microphone)
    statuses[.photoLibraryReadWrite] = AppPermissionCenter.status(for: .photoLibraryReadWrite)
  }

  private func actionTitle(for status: AppPermissionStatus) -> String? {
    switch status {
    case .authorized, .limited, .unavailable:
      return nil
    case .notDetermined:
      return "Allow"
    case .denied, .restricted:
      return "Open iOS Settings"
    }
  }

  private func handleAction(for permission: AppPermission, status: AppPermissionStatus) {
    switch status {
    case .notDetermined:
      Task {
        _ = await AppPermissionCenter.request(permission)
        await MainActor.run {
          refreshStatuses()
        }
      }
    case .denied, .restricted:
      AppPermissionCenter.openAppSettings()
    case .authorized, .limited, .unavailable:
      break
    }
  }
}
