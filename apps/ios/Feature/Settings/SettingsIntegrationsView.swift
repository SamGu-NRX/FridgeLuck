import SwiftUI

struct SettingsIntegrationsView: View {
  @EnvironmentObject private var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let refreshID: Int
  let onRequestAppleHealth: () -> Void

  @State private var appleHealthStatus: AppPermissionStatus = .notDetermined
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Connected services")
          .font(.system(.subheadline, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        appleHealthCard()
          .padding(.horizontal, AppTheme.Space.page)

        FLSettingsFootnote(
          text:
            "FridgeLuck can read nutrition totals and write completed meal logs only when you allow access."
        )
        .padding(.horizontal, AppTheme.Space.page)
      }
      .padding(.vertical, AppTheme.Space.md)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Integrations")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task(id: refreshID) { load() }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  private func appleHealthCard() -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "heart.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(AppTheme.sage, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text("Apple Health")
            .font(AppTheme.Typography.settingsBody)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Sync nutrition and meal data")
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        statusIndicator(appleHealthStatus)
      }

      if let action = actionForStatus(appleHealthStatus) {
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
    .accessibilityLabel("Apple Health, \(appleHealthStatus.settingsLabel)")
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

  private struct IntegrationAction {
    let title: String
    let icon: String
    let tint: Color
    let handler: () -> Void
  }

  private func actionForStatus(_ status: AppPermissionStatus) -> IntegrationAction? {
    switch status {
    case .notDetermined:
      return IntegrationAction(
        title: "Connect", icon: "link", tint: AppTheme.sage,
        handler: onRequestAppleHealth
      )
    case .denied, .restricted:
      return IntegrationAction(
        title: "Open Settings", icon: "gear", tint: AppTheme.textSecondary,
        handler: { AppPermissionCenter.openAppSettings() }
      )
    case .authorized, .limited, .unavailable:
      return nil
    }
  }

  private func load() {
    appleHealthStatus = deps.appleHealthService.authorizationStatus()
  }
}
