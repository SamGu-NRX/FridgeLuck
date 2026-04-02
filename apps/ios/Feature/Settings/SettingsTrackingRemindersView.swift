import SwiftUI

struct SettingsTrackingRemindersView: View {
  @EnvironmentObject private var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var rulesByKind: [NotificationRuleKind: NotificationRule] = [:]
  @State private var notificationStatus: AppPermissionStatus = .notDetermined
  @State private var editingKind: NotificationRuleKind?
  @State private var editingTime = Date()
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        permissionCard()
        mealReminderCard()
        kitchenAlertCard()

        FLSettingsFootnote(
          text:
            "Meal reminders are fixed-time nudges. Kitchen alerts are built from what is actually close to expiring."
        )
        .padding(.horizontal, AppTheme.Space.page)
      }
      .padding(.vertical, AppTheme.Space.md)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Tracking Reminders")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task {
      await load()
    }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
    .sheet(item: $editingKind) { kind in
      reminderTimeSheet(for: kind)
        .presentationDetents([.height(320)])
    }
  }

  private func permissionCard() -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "bell.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(AppTheme.oat, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text("Notifications")
            .font(AppTheme.Typography.settingsBody)
            .foregroundStyle(AppTheme.textPrimary)

          Text(notificationStatus.settingsDetail)
            .font(AppTheme.Typography.settingsCaption)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        statusIndicator(notificationStatus)
      }

      if let action = permissionAction {
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
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(action.tint)
          )
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
    .padding(.horizontal, AppTheme.Space.page)
  }

  private func mealReminderCard() -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      sectionHeader("Meal reminders")

      VStack(spacing: 0) {
        ForEach(NotificationRuleKind.orderedMealKinds, id: \.self) { kind in
          if let rule = rulesByKind[kind] {
            reminderRow(rule)
            if kind != NotificationRuleKind.orderedMealKinds.last {
              Divider()
                .overlay(AppTheme.oat.opacity(0.16))
            }
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .fill(AppTheme.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
      )
    }
    .padding(.horizontal, AppTheme.Space.page)
  }

  private func kitchenAlertCard() -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      sectionHeader("Kitchen alerts")

      if let rule = rulesByKind[.useSoonAlerts] {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          HStack(spacing: AppTheme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
              Text(rule.kind.title)
                .font(AppTheme.Typography.settingsBody)
                .foregroundStyle(AppTheme.textPrimary)

              Text(rule.kind.detail)
                .font(AppTheme.Typography.settingsCaption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Text(timeString(for: rule))
              .font(AppTheme.Typography.settingsDetail)
              .foregroundStyle(AppTheme.textSecondary)

            Toggle(
              "",
              isOn: Binding(
                get: { rulesByKind[.useSoonAlerts]?.enabled ?? false },
                set: { isEnabled in
                  updateRule(kind: .useSoonAlerts) { $0.enabled = isEnabled }
                }
              )
            )
            .labelsHidden()
            .tint(AppTheme.accent)
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
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
  }

  private func reminderRow(_ rule: NotificationRule) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Text(rule.kind.title)
        .font(AppTheme.Typography.settingsBody)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()

      Button {
        editingTime = date(for: rule)
        editingKind = rule.kind
      } label: {
        Text(timeString(for: rule))
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.sm)
          .padding(.vertical, AppTheme.Space.xxs)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(AppTheme.surfaceMuted)
          )
      }
      .buttonStyle(.plain)

      Toggle(
        "",
        isOn: Binding(
          get: { rulesByKind[rule.kind]?.enabled ?? false },
          set: { isEnabled in
            updateRule(kind: rule.kind) { $0.enabled = isEnabled }
          }
        )
      )
      .labelsHidden()
      .tint(AppTheme.accent)
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
  }

  private func reminderTimeSheet(for kind: NotificationRuleKind) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      Text(kind.title)
        .font(AppTheme.Typography.settingsHeadline)
        .foregroundStyle(AppTheme.textPrimary)
        .padding(.top, AppTheme.Space.md)

      DatePicker(
        "",
        selection: $editingTime,
        displayedComponents: .hourAndMinute
      )
      .datePickerStyle(.wheel)
      .labelsHidden()

      FLPrimaryButton("Done") {
        let components = Calendar.current.dateComponents([.hour, .minute], from: editingTime)
        updateRule(kind: kind) { rule in
          rule.hour = components.hour ?? rule.hour
          rule.minute = components.minute ?? rule.minute
        }
        editingKind = nil
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.md)
    }
    .presentationDragIndicator(.visible)
    .background(AppTheme.bg)
  }

  private var permissionAction: (title: String, icon: String, tint: Color, handler: () -> Void)? {
    switch notificationStatus {
    case .notDetermined:
      return (
        "Allow Notifications",
        "bell.badge.fill",
        AppTheme.accent,
        {
          Task {
            _ = await deps.notificationCoordinator.requestAuthorizationIfNeeded()
            await load()
          }
        }
      )
    case .denied, .restricted:
      return (
        "Open Settings",
        "gear",
        AppTheme.textSecondary,
        {
          AppPermissionCenter.openAppSettings()
        }
      )
    case .authorized, .limited, .unavailable:
      return nil
    }
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
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(status.statusColor.opacity(0.12))
        )
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(.subheadline, design: .serif, weight: .medium))
      .foregroundStyle(AppTheme.textSecondary)
  }

  private func load() async {
    notificationStatus = await deps.notificationPermissionService.status()
    rulesByKind = Dictionary(
      uniqueKeysWithValues: ((try? deps.notificationRuleRepository.fetchAllRules()) ?? []).map {
        ($0.kind, $0)
      }
    )
  }

  private func updateRule(
    kind: NotificationRuleKind,
    mutate: (inout NotificationRule) -> Void
  ) {
    var rule = rulesByKind[kind] ?? NotificationRule.makeDefault(kind: kind)
    mutate(&rule)
    rulesByKind[kind] = rule

    Task {
      try? deps.notificationRuleRepository.saveRule(
        kind: kind,
        enabled: rule.enabled,
        hour: rule.hour,
        minute: rule.minute
      )

      if kind == .useSoonAlerts {
        await deps.notificationCoordinator.refreshFreshnessOpportunities()
      } else {
        await deps.notificationCoordinator.refreshLocalSchedules()
      }
    }
  }

  private func timeString(for rule: NotificationRule) -> String {
    Self.timeFormatter.string(from: date(for: rule))
  }

  private func date(for rule: NotificationRule) -> Date {
    Calendar.current.date(
      bySettingHour: rule.hour,
      minute: rule.minute,
      second: 0,
      of: Date()
    ) ?? Date()
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
  }()
}
