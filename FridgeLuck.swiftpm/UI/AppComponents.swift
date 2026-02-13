import SwiftUI

private struct FLPressableButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}

struct FLCard<Content: View>: View {
  enum Tone {
    case normal
    case warm
    case success
    case warning

    var fill: Color {
      switch self {
      case .normal: return AppTheme.surface
      case .warm: return AppTheme.surfaceMuted
      case .success: return AppTheme.positive.opacity(0.08)
      case .warning: return AppTheme.warning.opacity(0.1)
      }
    }

    var stroke: Color {
      switch self {
      case .normal: return AppTheme.textSecondary.opacity(0.14)
      case .warm: return AppTheme.accent.opacity(0.25)
      case .success: return AppTheme.positive.opacity(0.28)
      case .warning: return AppTheme.warning.opacity(0.32)
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
        tone.fill, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(tone.stroke, lineWidth: 1)
      )
      .shadow(
        color: AppTheme.Shadow.color, radius: AppTheme.Shadow.radius, x: 0, y: AppTheme.Shadow.y)
  }
}

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
    HStack(alignment: .top, spacing: AppTheme.Space.sm) {
      Image(systemName: icon)
        .foregroundStyle(AppTheme.accent)
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(title)
          .font(.headline)
          .foregroundStyle(AppTheme.textPrimary)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      Spacer()
    }
  }
}

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
      .font(.caption.bold())
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.xs)
      .foregroundStyle(kind.color)
      .background(kind.color.opacity(0.14), in: Capsule())
  }
}

struct FLPrimaryButton: View {
  enum LabelAnimation {
    case none
    case subtleBlend
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: String
  let systemImage: String?
  let isEnabled: Bool
  let labelAnimation: LabelAnimation
  let action: () -> Void

  @State private var labelScale: CGFloat = 1
  @State private var labelBlur: CGFloat = 0

  init(
    _ title: String, systemImage: String? = nil, isEnabled: Bool = true,
    labelAnimation: LabelAnimation = .none,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.labelAnimation = labelAnimation
    self.action = action
  }

  private var labelKey: String {
    "\(title)|\(systemImage ?? "none")"
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: AppTheme.Space.xs) {
        if let systemImage {
          Image(systemName: systemImage)
        }
        Text(title)
          .lineLimit(1)
      }
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.md)
      .scaleEffect(labelScale)
      .blur(radius: labelBlur)
      .background(
        isEnabled ? AppTheme.accent : AppTheme.neutral.opacity(0.3),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .foregroundStyle(isEnabled ? AppTheme.textPrimary : AppTheme.textSecondary)
      .transaction(value: title) { transaction in
        transaction.animation = nil
      }
      .transaction(value: systemImage ?? "") { transaction in
        transaction.animation = nil
      }
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(!isEnabled)
    .onChange(of: labelKey) { _, _ in
      guard labelAnimation == .subtleBlend, !reduceMotion else { return }
      labelScale = 0.988
      labelBlur = 0.8
      withAnimation(AppMotion.quick) {
        labelScale = 1
        labelBlur = 0
      }
    }
  }
}

struct FLSecondaryButton: View {
  let title: String
  let systemImage: String?
  let isEnabled: Bool
  let action: () -> Void

  init(
    _ title: String,
    systemImage: String? = nil,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: AppTheme.Space.xs) {
        if let systemImage {
          Image(systemName: systemImage)
        }
        Text(title)
          .lineLimit(1)
      }
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.md)
      .background(
        isEnabled ? AppTheme.surface : AppTheme.surfaceMuted.opacity(0.7),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.textSecondary.opacity(0.25), lineWidth: 1)
      )
      .foregroundStyle(isEnabled ? AppTheme.textPrimary : AppTheme.textSecondary)
      .transaction(value: title) { transaction in
        transaction.animation = nil
      }
      .transaction(value: systemImage ?? "") { transaction in
        transaction.animation = nil
      }
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(!isEnabled)
  }
}

struct FLActionBar<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(spacing: AppTheme.Space.xs) {
      content
    }
    .padding(.vertical, AppTheme.Space.sm)
    .background(AppTheme.bg)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(AppTheme.textSecondary.opacity(0.14))
        .frame(height: 1)
    }
  }
}

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
    FLCard(tone: .warm) {
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: systemImage)
          .font(.system(size: 34))
          .foregroundStyle(AppTheme.textSecondary)
        Text(title)
          .font(.headline)
          .foregroundStyle(AppTheme.textPrimary)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
        if let actionTitle, let action {
          FLSecondaryButton(actionTitle, action: action)
        }
      }
    }
  }
}
