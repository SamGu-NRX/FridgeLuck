import SwiftUI

struct FLSettingsSummaryCard: View {
  let title: String
  let subtitle: String

  private var initial: String {
    String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
  }

  var body: some View {
    HStack(spacing: AppTheme.Space.md) {
      Text(initial)
        .font(.system(.title3, design: .serif, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(
          Circle()
            .fill(
              LinearGradient(
                colors: [AppTheme.accent, AppTheme.accentLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(title)
          .font(.system(.title3, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(1)

        Text(subtitle)
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(2)
      }

      Spacer(minLength: 0)
    }
    .padding(AppTheme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(AppTheme.surfaceElevated.opacity(0.96))
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(AppTheme.accent)
        .frame(width: 3)
        .padding(.vertical, AppTheme.Space.sm)
        .padding(.leading, 1)
    }
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }
}

struct FLSettingsBadge: Identifiable, Hashable {
  enum Tone {
    case neutral
    case accent
    case positive
    case warning

    var foreground: Color {
      switch self {
      case .neutral: return AppTheme.textSecondary
      case .accent: return AppTheme.accent
      case .positive: return AppTheme.sage
      case .warning: return AppTheme.accent
      }
    }

    var background: Color {
      switch self {
      case .neutral: return AppTheme.surfaceMuted
      case .accent: return AppTheme.accent.opacity(0.10)
      case .positive: return AppTheme.sage.opacity(0.12)
      case .warning: return AppTheme.accent.opacity(0.12)
      }
    }
  }

  let id: String
  let text: String
  let tone: Tone

  init(id: String? = nil, text: String, tone: Tone) {
    self.id = id ?? "\(text)-\(tone)"
    self.text = text
    self.tone = tone
  }
}

struct FLSettingsBadgeView: View {
  let badge: FLSettingsBadge

  var body: some View {
    Text(badge.text)
      .font(AppTheme.Typography.settingsCaptionMedium)
      .foregroundStyle(badge.tone.foreground)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.xxs)
      .background(
        Capsule(style: .continuous)
          .fill(badge.tone.background)
      )
  }
}

struct FLSettingsDisclosureRow: View {
  let title: String
  let value: String
  let subtitle: String?

  init(
    title: String,
    value: String,
    subtitle: String? = nil
  ) {
    self.title = title
    self.value = value
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
        Text(title)
          .font(AppTheme.Typography.settingsBody)
          .foregroundStyle(AppTheme.textPrimary)

        Spacer(minLength: AppTheme.Space.sm)

        if !value.isEmpty {
          Text(value)
            .font(AppTheme.Typography.settingsDetail)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.trailing)
        }
      }

      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(AppTheme.Typography.settingsCaption)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(.vertical, AppTheme.Space.xxxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)\(value.isEmpty ? "" : ", \(value)")")
    .accessibilityHint(subtitle ?? "")
  }
}

struct FLSettingsStatusRow: View {
  let title: String
  let status: String
  let detail: String
  let badge: FLSettingsBadge

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack(alignment: .center, spacing: AppTheme.Space.sm) {
        Text(title)
          .font(AppTheme.Typography.settingsBody)
          .foregroundStyle(AppTheme.textPrimary)

        Spacer(minLength: AppTheme.Space.sm)

        FLSettingsBadgeView(badge: badge)
      }

      Text("\(status). \(detail)")
        .font(AppTheme.Typography.settingsCaption)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.vertical, AppTheme.Space.xxxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(badge.text). \(status). \(detail)")
  }
}

struct FLSettingsFootnote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(AppTheme.Typography.settingsCaption)
      .foregroundStyle(AppTheme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct FLSettingsDestructiveGroup: View {
  let title: String
  let message: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text(title)
        .font(AppTheme.Typography.settingsHeadline)
        .foregroundStyle(AppTheme.textPrimary)

      Text(message)
        .font(AppTheme.Typography.settingsDetail)
        .foregroundStyle(AppTheme.textSecondary)

      Button(
        role: .destructive,
        action: {
          AppPreferencesStore.notification(.warning)
          action()
        }
      ) {
        Text(actionTitle)
          .font(AppTheme.Typography.settingsBodySemibold)
          .frame(maxWidth: .infinity)
          .padding(.vertical, AppTheme.Space.sm)
      }
      .buttonStyle(.bordered)
      .tint(AppTheme.accent)
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(AppTheme.surfaceElevated.opacity(0.98))
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.accent.opacity(0.24), lineWidth: 1)
    )
  }
}
