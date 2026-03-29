import SwiftUI

// MARK: - Card

struct FLCard<Content: View>: View {
  enum Tone {
    case normal
    case warm
    case success
    case warning

    var fill: Color {
      switch self {
      case .normal: return AppTheme.surfaceElevated
      case .warm: return AppTheme.surfaceMuted
      case .success: return AppTheme.sage.opacity(0.08)
      case .warning: return AppTheme.accent.opacity(0.07)
      }
    }

    var stroke: Color {
      switch self {
      case .normal: return AppTheme.oat.opacity(0.30)
      case .warm: return AppTheme.oat.opacity(0.40)
      case .success: return AppTheme.sage.opacity(0.30)
      case .warning: return AppTheme.accent.opacity(0.28)
      }
    }
  }

  let tone: Tone
  let content: Content

  init(tone: Tone = .normal, @ViewBuilder content: () -> Content) {
    self.tone = tone
    self.content = content()
  }

  var body: some View {
    content
      .padding(AppTheme.Space.md)
      .background(
        tone.fill,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(tone.stroke, lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 8, x: 0, y: 3)
      .shadow(color: AppTheme.Shadow.colorDeep, radius: 20, x: 0, y: 10)
  }
}

// MARK: - Section Header

struct FLSectionHeader: View {
  let title: String
  let subtitle: String?
  let icon: String

  init(_ title: String, subtitle: String? = nil, icon: String) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: icon)
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 14, weight: .semibold))
        Text(title)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
      }
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.leading, 22)
      }
    }
  }
}

// MARK: - Status Pill

struct FLStatusPill: View {
  enum Kind {
    case positive
    case warning
    case neutral

    var color: Color {
      switch self {
      case .positive: return AppTheme.positive
      case .warning: return AppTheme.warning
      case .neutral: return AppTheme.neutral
      }
    }
  }

  let text: String
  let kind: Kind

  var body: some View {
    Text(text)
      .font(AppTheme.Typography.labelSmall)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .foregroundStyle(kind.color)
      .background(kind.color.opacity(0.12), in: Capsule())
  }
}

// MARK: - Empty State

struct FLEmptyState: View {
  let title: String
  let message: String
  let systemImage: String
  let actionTitle: String?
  let action: (() -> Void)?

  init(
    title: String,
    message: String,
    systemImage: String,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Image(systemName: systemImage)
        .font(.system(size: 34))
        .foregroundStyle(AppTheme.dustyRose)
      Text(title)
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)
      Text(message)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
      if let actionTitle, let action {
        FLSecondaryButton(actionTitle, action: action)
      }
    }
    .padding(AppTheme.Space.lg)
    .background(
      AppTheme.surfaceMuted,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
  }
}
