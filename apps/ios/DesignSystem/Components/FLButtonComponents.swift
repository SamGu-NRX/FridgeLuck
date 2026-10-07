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

// MARK: - Press Feedback

extension View {
  /// Press feedback shared by the app's button styles. With Reduce Motion on, a press dims the
  /// label instead of shrinking it, so the user still sees the tap land without movement.
  func pressFeedback(
    isPressed: Bool,
    scale pressedScale: CGFloat,
    opacity pressedOpacity: Double = 1,
    animation: Animation
  ) -> some View {
    modifier(
      PressFeedback(
        isPressed: isPressed,
        pressedScale: pressedScale,
        pressedOpacity: pressedOpacity,
        animation: animation
      ))
  }
}

private struct PressFeedback: ViewModifier {
  /// Under Reduce Motion a press dims to at least this much. Styles that already dim further
  /// keep their own value, so the two never multiply.
  private static let reducedMotionPressedOpacity = 0.7

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isPressed: Bool
  let pressedScale: CGFloat
  let pressedOpacity: Double
  let animation: Animation

  func body(content: Content) -> some View {
    let dimmed =
      reduceMotion ? min(pressedOpacity, Self.reducedMotionPressedOpacity) : pressedOpacity
    content
      .scaleEffect(isPressed && !reduceMotion ? pressedScale : 1)
      .opacity(isPressed ? dimmed : 1)
      // An opacity fade is gentle enough for Reduce Motion; the 120 ms press curve keeps it quick.
      .animation(reduceMotion ? AppMotion.press : animation, value: isPressed)
  }
}

// MARK: - Pressable Button Style

struct FLPressableButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .pressFeedback(
        isPressed: configuration.isPressed, scale: 0.96, animation: AppMotion.buttonSpring)
  }
}

// MARK: - Hero Card Button Style

struct FLHeroCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .pressFeedback(
        isPressed: configuration.isPressed, scale: 0.975, animation: AppMotion.cardSpring)
  }
}

// MARK: - Add Chip Button Style

struct FLAddChipButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .pressFeedback(
        isPressed: configuration.isPressed, scale: 0.92, opacity: 0.85,
        animation: AppMotion.press)
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
    .padding(.top, AppTheme.Space.xs)
    .padding(.bottom, AppTheme.Space.sm)
    .background(AppTheme.bg)
    .overlay(alignment: .top) {
      LinearGradient(
        colors: [
          AppTheme.oat.opacity(0.0),
          AppTheme.oat.opacity(0.12),
          AppTheme.oat.opacity(0.0),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(height: 1)
    }
  }
}
