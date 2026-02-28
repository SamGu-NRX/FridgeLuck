import SwiftUI

// MARK: - Button Style

private struct FLPressableButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: configuration.isPressed)
  }
}

// MARK: - Card

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

// MARK: - Section Header (serif title, terracotta icon)

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
        .font(.system(size: 15, weight: .semibold))
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(title)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      Spacer()
    }
  }
}

// MARK: - Status Pill (warm status colors)

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

// MARK: - Primary Button (terracotta fill, white text, generous)

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
      .font(.system(.headline, design: .serif, weight: .semibold))
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.buttonVertical)
      .scaleEffect(labelScale)
      .background(
        isEnabled ? AppTheme.accent : AppTheme.neutral.opacity(0.3),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .foregroundStyle(isEnabled ? .white : AppTheme.textSecondary)
      .shadow(
        color: isEnabled ? AppTheme.accent.opacity(0.25) : .clear,
        radius: 12, x: 0, y: 6
      )
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
      withAnimation(AppMotion.quick) {
        labelScale = 1
      }
    }
  }
}

// MARK: - Secondary Button (warm border, serif text)

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
      .font(.system(.headline, design: .serif, weight: .medium))
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.buttonVertical)
      .background(
        isEnabled ? AppTheme.surface : AppTheme.surfaceMuted.opacity(0.7),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.45), lineWidth: 1)
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

// MARK: - Action Bar

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
        .fill(AppTheme.oat.opacity(0.30))
        .frame(height: 1)
    }
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
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
  }
}

// MARK: - Stat Display

/// Large serif number + small rounded label. For streak counts, meal numbers, etc.
struct FLStatDisplay: View {
  let value: String
  let label: String
  var useDarkStyle: Bool = false

  var body: some View {
    VStack(spacing: AppTheme.Space.xxxs) {
      Text(value)
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(useDarkStyle ? AppTheme.surface : AppTheme.textPrimary)
        .contentTransition(.numericText())
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(
          useDarkStyle ? AppTheme.surface.opacity(0.65) : AppTheme.textSecondary
        )
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Analyzing Pulse Animation

/// Custom pulsing terracotta ring for analyzing states. Replaces generic ProgressView.
struct FLAnalyzingPulse: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isAnimating = false

  var body: some View {
    ZStack {
      Circle()
        .stroke(AppTheme.accent.opacity(0.20), lineWidth: 3)
        .scaleEffect(isAnimating ? 1.5 : 1.0)
        .opacity(isAnimating ? 0 : 0.6)

      Circle()
        .stroke(AppTheme.accent.opacity(0.15), lineWidth: 2)
        .scaleEffect(isAnimating ? 1.3 : 0.9)
        .opacity(isAnimating ? 0 : 0.5)

      Circle()
        .stroke(AppTheme.accent, lineWidth: 3)

      Circle()
        .fill(AppTheme.accent)
        .frame(width: 8, height: 8)
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(
        .easeInOut(duration: 1.6)
          .repeatForever(autoreverses: false)
      ) {
        isAnimating = true
      }
    }
  }
}
