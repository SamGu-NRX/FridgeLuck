import SwiftUI

private struct SettingsPermissionItem: Identifiable {
  let id: AppPermission
  let title: String
  let icon: String
  let tint: Color
  let description: String
}

struct SettingsPermissionsView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var statuses: [AppPermission: AppPermissionStatus] = [:]
  @State private var appeared = false

  private let items: [SettingsPermissionItem] = [
    SettingsPermissionItem(
      id: .camera, title: "Camera", icon: "camera.fill", tint: AppTheme.accent,
      description: "Scan your fridge and ingredients"
    ),
    SettingsPermissionItem(
      id: .microphone, title: "Microphone", icon: "mic.fill", tint: AppTheme.sage,
      description: "Voice commands during cooking"
    ),
    SettingsPermissionItem(
      id: .photoLibraryReadWrite, title: "Photo Library", icon: "photo.fill", tint: AppTheme.oat,
      description: "Save and import ingredient photos"
    ),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.sm) {
        ForEach(items) { item in
          permissionCard(for: item)
        }

        FLSettingsFootnote(
          text:
            "Permissions stay off until you explicitly allow them. Denied permissions must be changed in iOS Settings."
        )
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.top, AppTheme.Space.xs)
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Home.navOrbLift)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .navigationTitle("Permissions")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task { refreshStatuses() }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  private func permissionCard(for item: SettingsPermissionItem) -> some View {
    let status = statuses[item.id] ?? .notDetermined

    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: item.icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(item.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(AppTheme.Typography.settingsBody)
            .foregroundStyle(AppTheme.textPrimary)

          Text(item.description)
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        statusIndicator(status)
      }

      if let action = actionForStatus(status, permission: item.id) {
        Button(action: action.handler) {
          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: action.icon)
              .font(.system(size: 12, weight: .semibold))
            Text(action.title)
              .font(AppTheme.Typography.settingsCaptionMedium)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, AppTheme.Space.md)
          .padding(.vertical, AppTheme.Space.xs)
          .background(Capsule().fill(action.tint))
        }
      }
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(item.title), \(status.settingsLabel). \(item.description)"
    )
  }

  @ViewBuilder
  private func statusIndicator(_ status: AppPermissionStatus) -> some View {
    switch status {
    case .authorized:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(status.statusColor)
    default:
      Text(status.settingsLabel)
        .font(AppTheme.Typography.settingsCaptionMedium)
        .foregroundStyle(status.statusColor)
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.xxs)
        .background(
          Capsule().fill(status.statusColor.opacity(0.12))
        )
    }
  }

  private struct PermissionAction {
    let title: String
    let icon: String
    let tint: Color
    let handler: () -> Void
  }

  private func actionForStatus(_ status: AppPermissionStatus, permission: AppPermission)
    -> PermissionAction?
  {
    switch status {
    case .notDetermined:
      return PermissionAction(title: "Allow", icon: "hand.thumbsup.fill", tint: AppTheme.accent) {
        Task {
          _ = await AppPermissionCenter.request(permission)
          await MainActor.run { refreshStatuses() }
        }
      }
    case .denied, .restricted:
      return PermissionAction(title: "Open Settings", icon: "gear", tint: AppTheme.textSecondary) {
        AppPermissionCenter.openAppSettings()
      }
    case .limited:
      return PermissionAction(title: "Manage Access", icon: "gear", tint: AppTheme.oat) {
        AppPermissionCenter.openAppSettings()
      }
    case .authorized, .unavailable:
      return nil
    }
  }

  private func refreshStatuses() {
    statuses[.camera] = AppPermissionCenter.status(for: .camera)
    statuses[.microphone] = AppPermissionCenter.status(for: .microphone)
    statuses[.photoLibraryReadWrite] = AppPermissionCenter.status(for: .photoLibraryReadWrite)
  }
}
