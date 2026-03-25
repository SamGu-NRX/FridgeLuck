import SwiftUI

// MARK: - Primary Button

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
    _ title: String,
    systemImage: String? = nil,
    isEnabled: Bool = true,
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
      .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isEnabled)
      .shadow(color: isEnabled ? AppTheme.accent.opacity(0.25) : .clear, radius: 12, x: 0, y: 6)
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

// MARK: - Secondary Button

struct FLSecondaryButton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
      .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isEnabled)
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

// MARK: - Pressable Button Style

struct FLPressableButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: configuration.isPressed)
  }
}

// MARK: - Hero Card Button Style

struct FLHeroCardButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.cardSpring, value: configuration.isPressed)
  }
}

// MARK: - Add Chip Button Style

struct FLAddChipButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
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
