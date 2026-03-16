import AuthenticationServices
import SwiftUI
import UIKit

// MARK: - Shared Types

struct DietOption: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let icon: FLIcon
}

private enum OnboardingTypography {
  static let sectionTitle = Font.system(.title, design: .serif, weight: .bold)
  static let welcomeTitle = Font.system(.largeTitle, design: .serif, weight: .bold)
  static let bridgeTitle = Font.system(.title2, design: .serif, weight: .bold)
}

// MARK: - Stagger Entrance Modifier

/// Applies a delayed opacity + offset animation for choreographed step entrances.
/// Each element in a step gets an incremental `index` so they appear one-by-one.
private struct StaggerIn: ViewModifier {
  let index: Int
  let appeared: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(reduceMotion || appeared ? 1 : 0)
      .offset(y: reduceMotion || appeared ? 0 : 14)
      .animation(
        reduceMotion
          ? nil
          : AppMotion.staggerEntrance.delay(Double(index) * AppMotion.staggerInterval),
        value: appeared
      )
  }
}

// MARK: - Step 0: Welcome Hero

struct OnboardingWelcomeHeroStep: View {
  let onContinueWithoutApple: () -> Void
  let onAppleSignInRequest: (ASAuthorizationAppleIDRequest) -> Void
  let onAppleSignInCompletion: (Result<ASAuthorization, Error>) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                AppTheme.heroLight.opacity(0.9),
                AppTheme.accentLight.opacity(0.45),
                Color.clear,
              ],
              center: .center,
              startRadius: 18,
              endRadius: 130
            )
          )
          .frame(width: 260, height: 260)
          .blur(radius: 22)
          .opacity(appeared ? 1 : 0)
          .animation(
            reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.05),
            value: appeared
          )

        RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
              .fill(AppTheme.surface.opacity(0.78))
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.28), lineWidth: 1)
          )
          .frame(width: 152, height: 152)
          .shadow(color: AppTheme.Shadow.colorDeep, radius: 24, x: 0, y: 12)

        if UIImage(named: "FridgeLuckLogo") != nil {
          Image("FridgeLuckLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 90, height: 90)
        } else {
          Image(systemName: "refrigerator.fill")
            .font(.system(size: 50, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }
      }
      .scaleEffect(appeared ? 1 : 0.92)
      .opacity(appeared ? 1 : 0)
      .animation(
        reduceMotion ? nil : AppMotion.heroEntrance.delay(0.1),
        value: appeared
      )

      Spacer()
        .frame(height: AppTheme.Space.lg)

      HStack(spacing: AppTheme.Space.sm) {
        heroPill(icon: "camera.macro", text: "Scan", delay: 0.28)
        heroPill(icon: "fork.knife", text: "Cook", delay: 0.34)
        heroPill(icon: "heart.text.square", text: "Track", delay: 0.40)
      }

      Spacer()
        .frame(height: AppTheme.Space.xxl)

      VStack(spacing: AppTheme.Space.sm) {
        Text("Turn what you have\ninto meals you can trust.")
          .font(OnboardingTypography.welcomeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Text("Simple enough for a first-time cook.\nSmart enough to keep up every day.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, AppTheme.Space.page)
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 14)
      .animation(
        reduceMotion ? nil : .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.34).delay(0.42),
        value: appeared
      )

      Spacer()

      VStack(spacing: AppTheme.Space.sm) {
        Button(action: onContinueWithoutApple) {
          Text("Get Started")
            .font(.system(.headline, design: .serif, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Space.buttonVertical)
            .background(
              AppTheme.accent,
              in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
            )
            .foregroundStyle(.white)
            .shadow(color: AppTheme.accent.opacity(0.25), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(FLPressableButtonStyle())

        SignInWithAppleButton(
          .continue,
          onRequest: onAppleSignInRequest,
          onCompletion: onAppleSignInCompletion
        )
        .signInWithAppleButtonStyle(.black)
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .shadow(color: AppTheme.Shadow.colorDeep.opacity(0.16), radius: 12, x: 0, y: 6)
        .accessibilityLabel("Continue with Apple")
        .accessibilityHint(
          "Optionally prefills your name from Apple when the capability is available.")
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.lg)
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 10)
      .animation(
        reduceMotion ? nil : .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.30).delay(0.58),
        value: appeared
      )
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 80_000_000)
      appeared = true
    }
  }

  private func heroPill(icon: String, text: String, delay: Double) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
      Text(text)
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textPrimary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(AppTheme.surface, in: Capsule())
    .overlay(Capsule().stroke(AppTheme.oat.opacity(0.22), lineWidth: 1))
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.heroPill.delay(delay),
      value: appeared
    )
  }
}

// MARK: - Step 1: Name Input

struct OnboardingNameStep: View {
  @Binding var displayName: String
  @FocusState.Binding var isNameFocused: Bool
  let validationMessage: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 80)

      VStack(spacing: AppTheme.Space.lg) {
        Text("What's your name?")
          .font(OnboardingTypography.sectionTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
          .modifier(StaggerIn(index: 0, appeared: appeared))

        Text("We'll use this to personalize your experience.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .modifier(StaggerIn(index: 1, appeared: appeared))

        TextField("Your name", text: $displayName)
          .font(.system(size: 24, weight: .medium, design: .serif))
          .multilineTextAlignment(.center)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .focused($isNameFocused)
          .padding(.vertical, AppTheme.Space.md)
          .padding(.horizontal, AppTheme.Space.md)
          .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
              .fill(AppTheme.surfaceMuted.opacity(0.5))
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
              .stroke(
                isNameFocused ? AppTheme.accent.opacity(0.6) : AppTheme.oat.opacity(0.3),
                lineWidth: isNameFocused ? 1.5 : 1
              )
          )
          .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isNameFocused)
          .padding(.horizontal, AppTheme.Space.xl)
          .modifier(StaggerIn(index: 2, appeared: appeared))

        if let validationMessage {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(validationMessage)
          }
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.warning)
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }
}

// MARK: - Step 2: Personal Welcome

struct OnboardingPersonalWelcomeStep: View {
  let displayName: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var showConfetti = false

  private var timeGreeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12: return "Great morning to set up your kitchen."
    case 12..<17: return "Perfect time to get organized."
    default: return "Let's get you ready for tomorrow."
    }
  }

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        Spacer()
          .frame(maxHeight: 90)

        VStack(spacing: AppTheme.Space.lg) {
          Text("Welcome, \(displayName)!")
            .font(OnboardingTypography.welcomeTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .modifier(StaggerIn(index: 0, appeared: appeared))

          VStack(spacing: AppTheme.Space.md) {
            Text(timeGreeting)
              .font(AppTheme.Typography.bodyLarge)
              .foregroundStyle(AppTheme.textSecondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .modifier(StaggerIn(index: 1, appeared: appeared))

            Text("Let's set up your kitchen profile so\nFridgeLuck can work its magic.")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .modifier(StaggerIn(index: 2, appeared: appeared))

            HStack(spacing: AppTheme.Space.md) {
              welcomeFeature(icon: "fork.knife", text: "Personalized\nrecipes", index: 3)
              welcomeFeature(icon: "shield.lefthalf.filled", text: "Allergen\nsafety", index: 4)
              welcomeFeature(icon: "chart.bar", text: "Nutrition\ntracking", index: 5)
            }
            .padding(.top, AppTheme.Space.md)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        Spacer()
      }

      if showConfetti {
        ConfettiOverlay(particleCount: 24)
          .allowsHitTesting(false)
      }
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
      if !reduceMotion {
        try? await Task.sleep(nanoseconds: 350_000_000)
        showConfetti = true
      }
    }
  }

  private func welcomeFeature(icon: String, text: String, index: Int) -> some View {
    VStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(AppTheme.accent)
        .frame(width: 48, height: 48)
        .background(AppTheme.accent.opacity(0.10), in: Circle())

      Text(text)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .modifier(StaggerIn(index: index, appeared: appeared))
  }
}

// MARK: - Step 3: Age (Horizontal Scroll Ruler)

struct OnboardingAgeStep: View {
  @Binding var age: Int
  let reduceMotion: Bool
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 60)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("How old are you?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("This helps us tailor nutrition recommendations.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .modifier(StaggerIn(index: 0, appeared: appeared))

        VStack(spacing: AppTheme.Space.sm) {
          Text("\(age)")
            .font(.system(size: 64, weight: .bold, design: .serif))
            .foregroundStyle(AppTheme.textPrimary)
            .contentTransition(.numericText(value: Double(age)))
            .animation(reduceMotion ? nil : AppMotion.rulerSnap, value: age)

          Text("years old")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .modifier(StaggerIn(index: 1, appeared: appeared))

        HorizontalScrollRuler(
          value: $age,
          range: 13...100,
          reduceMotion: reduceMotion
        )
        .modifier(StaggerIn(index: 2, appeared: appeared))
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }
}

// MARK: - Horizontal Scroll Ruler

struct HorizontalScrollRuler: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let reduceMotion: Bool

  @State private var dragOffset: CGFloat = 0
  @State private var baseValue: Int = 0
  @GestureState private var isDragging = false

  private let tickSpacing: CGFloat = 12
  private let majorTickInterval = 5

  var body: some View {
    GeometryReader { geo in
      let center = geo.size.width / 2

      ZStack {
        Canvas { context, size in
          let totalTicks = range.upperBound - range.lowerBound
          let centerY = size.height / 2

          for i in 0...totalTicks {
            let tickValue = range.lowerBound + i
            let xOffset = CGFloat(tickValue - value) * tickSpacing + dragOffset + center
            guard xOffset > -tickSpacing, xOffset < size.width + tickSpacing else { continue }

            let isMajor = (tickValue % majorTickInterval) == 0
            let distFromCenter = abs(xOffset - center)
            let fadeAlpha = max(0, 1.0 - distFromCenter / (size.width * 0.48))

            let tickHeight: CGFloat = isMajor ? 28 : 14
            let tickWidth: CGFloat = isMajor ? 2 : 1
            let tickColor: Color = isMajor ? AppTheme.textPrimary : AppTheme.oat

            let rect = CGRect(
              x: xOffset - tickWidth / 2,
              y: centerY - tickHeight / 2,
              width: tickWidth,
              height: tickHeight
            )
            context.opacity = fadeAlpha
            context.fill(
              Path(roundedRect: rect, cornerRadius: tickWidth / 2),
              with: .color(tickColor)
            )

            if isMajor {
              let text = Text("\(tickValue)")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
              context.draw(
                context.resolve(text),
                at: CGPoint(x: xOffset, y: centerY + tickHeight / 2 + 12)
              )
            }
          }
        }

        VStack(spacing: 0) {
          RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.accent)
            .frame(width: 3, height: 36)
        }
        .position(x: center, y: geo.size.height / 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($isDragging) { _, state, _ in state = true }
          .onChanged { gesture in
            dragOffset = gesture.translation.width
            setValue(for: gesture.translation.width, from: baseValue)
          }
          .onEnded { gesture in
            let finalValue = resolvedValue(for: gesture.translation.width, from: baseValue)
            value = finalValue
            baseValue = finalValue
            if reduceMotion {
              dragOffset = 0
            } else {
              withAnimation(AppMotion.rulerSnap) {
                dragOffset = 0
              }
            }
          }
      )
      .onChange(of: isDragging) { _, dragging in
        if dragging {
          baseValue = value
          dragOffset = 0
        }
      }
    }
    .frame(height: 72)
    .clipped()
    .onAppear {
      baseValue = value
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Age")
    .accessibilityValue("\(value) years old")
    .accessibilityHint("Swipe up or down with one finger to adjust.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        step(by: 1)
      case .decrement:
        step(by: -1)
      @unknown default:
        break
      }
    }
  }

  private func resolvedValue(for translationWidth: CGFloat, from baseValue: Int) -> Int {
    let rawValue = Double(baseValue) + Double(-translationWidth) / Double(tickSpacing)
    return clampedValue(Int(rawValue.rounded()))
  }

  private func setValue(for translationWidth: CGFloat, from baseValue: Int) {
    let nextValue = resolvedValue(for: translationWidth, from: baseValue)
    if nextValue != value {
      value = nextValue
    }
  }

  private func step(by delta: Int) {
    let nextValue = clampedValue(value + delta)
    guard nextValue != value else { return }
    value = nextValue
    baseValue = nextValue
  }

  private func clampedValue(_ candidate: Int) -> Int {
    min(max(candidate, range.lowerBound), range.upperBound)
  }
}

// MARK: - Step 4: Goal Selection

struct OnboardingGoalStep: View {
  @Binding var goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  private struct GoalOption: Identifiable {
    let id: HealthGoal
    let icon: String
    let description: String
    let accent: Color
  }

  private let options: [GoalOption] = [
    .init(
      id: .general, icon: "heart", description: "Balanced nutrition for everyday wellness",
      accent: AppTheme.sage),
    .init(
      id: .weightLoss, icon: "flame", description: "Lower calorie target to support weight loss",
      accent: AppTheme.accent),
    .init(
      id: .muscleGain, icon: "dumbbell",
      description: "Higher protein and calories for muscle growth", accent: AppTheme.oat),
    .init(
      id: .maintenance, icon: "scale.3d", description: "Maintain your current weight and energy",
      accent: AppTheme.dustyRose),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("What's your goal?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Pick your primary nutrition direction.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .modifier(StaggerIn(index: 0, appeared: appeared))

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
            goalCard(option)
              .modifier(StaggerIn(index: offset + 1, appeared: appeared))
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private func goalCard(_ option: GoalOption) -> some View {
    let selected = goal == option.id

    return Button {
      goal = option.id
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        Image(systemName: option.icon)
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(selected ? option.accent : AppTheme.textSecondary)
          .frame(width: 44, height: 44)
          .background(
            (selected ? option.accent : AppTheme.oat).opacity(selected ? 0.15 : 0.10),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          )

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(option.id.displayName)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)

          Text(option.description)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(2)
        }

        Spacer(minLength: 0)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? option.accent : AppTheme.oat.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        selected ? option.accent.opacity(0.08) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(
            selected ? option.accent.opacity(0.40) : AppTheme.oat.opacity(0.25),
            lineWidth: selected ? 1.5 : 1
          )
      )
      .shadow(
        color: selected ? option.accent.opacity(0.12) : AppTheme.Shadow.color,
        radius: selected ? 10 : 4,
        x: 0,
        y: selected ? 4 : 2
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .animation(reduceMotion ? nil : AppMotion.selectionPress, value: selected)
  }
}

// MARK: - Step 5: Feature Bridge — Scan

struct OnboardingFeatureScanStep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: AppTheme.Space.md)

      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
          .fill(
            LinearGradient(
              colors: [AppTheme.surface, AppTheme.bgDeep.opacity(0.65)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
          )
          .shadow(color: AppTheme.Shadow.colorDeep, radius: 18, x: 0, y: 12)

        VStack(spacing: AppTheme.Space.md) {
          if let image = DemoScanService.loadScenarioImage(for: .asianStirFry) {
            ZStack(alignment: .bottom) {
              Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 210)
                .clipShape(
                  RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
                )

              HStack(spacing: AppTheme.Space.xs) {
                ingredientPill("Garlic")
                ingredientPill("Onions")
                ingredientPill("Soy sauce")
              }
              .padding(.bottom, AppTheme.Space.sm)
              .modifier(StaggerIn(index: 2, appeared: appeared))
            }
          }

          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: "sparkles")
              .foregroundStyle(AppTheme.accent)
            Text("Detected in seconds")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .padding(AppTheme.Space.lg)
      }
      .frame(maxHeight: 330)
      .padding(.horizontal, AppTheme.Space.page)
      .modifier(StaggerIn(index: 0, appeared: appeared))

      Spacer()
        .frame(height: AppTheme.Space.xl)

      VStack(spacing: AppTheme.Space.sm) {
        Text("SEE YOUR KITCHEN")
          .font(AppTheme.Typography.label)
          .textCase(.uppercase)
          .kerning(1.1)
          .foregroundStyle(AppTheme.accent)
          .modifier(StaggerIn(index: 3, appeared: appeared))

        Text("Snap your shelf, know\nyour ingredients.")
          .font(OnboardingTypography.bridgeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .modifier(StaggerIn(index: 4, appeared: appeared))

        Text(
          "Point your camera at what you already have and FridgeLuck turns it into ingredients you can cook with."
        )
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(StaggerIn(index: 5, appeared: appeared))
      }
      .frame(maxWidth: 540)
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private func ingredientPill(_ name: String) -> some View {
    Text(name)
      .font(AppTheme.Typography.label)
      .foregroundStyle(AppTheme.textPrimary)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
  }
}

// MARK: - Step 6: Daily Calorie Target

struct OnboardingCalorieStep: View {
  @Binding var dailyCalories: Int
  let goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 60)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("Daily calorie target")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Adjust to match your lifestyle. Pre-filled for your goal.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .modifier(StaggerIn(index: 0, appeared: appeared))

        VStack(spacing: AppTheme.Space.md) {
          HStack(spacing: AppTheme.Space.sm) {
            Button {
              dailyCalories = max(1000, dailyCalories - 50)
            } label: {
              Image(systemName: "minus")
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
                .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(.plain)

            Text("\(dailyCalories)")
              .font(.system(size: 56, weight: .bold, design: .serif))
              .foregroundStyle(AppTheme.textPrimary)
              .frame(maxWidth: .infinity)
              .contentTransition(.numericText(value: Double(dailyCalories)))
              .animation(reduceMotion ? nil : AppMotion.quick, value: dailyCalories)

            Button {
              dailyCalories = min(4500, dailyCalories + 50)
            } label: {
              Image(systemName: "plus")
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(AppTheme.surfaceMuted, in: Circle())
                .overlay(Circle().stroke(AppTheme.oat.opacity(0.25), lineWidth: 1))
                .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(.plain)
          }

          Text("kcal / day")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)

          Slider(
            value: Binding(
              get: { Double(dailyCalories) },
              set: { dailyCalories = Int($0.rounded()) }
            ),
            in: 1000...4500,
            step: 50
          )
          .tint(AppTheme.accent)
          .padding(.horizontal, AppTheme.Space.sm)
        }
        .modifier(StaggerIn(index: 1, appeared: appeared))
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }
}

// MARK: - Step 7: Diet Selection (Single-select)

struct OnboardingDietStep: View {
  let options: [DietOption]
  let selectedDiet: String
  let onSelect: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        VStack(spacing: AppTheme.Space.xs) {
          Text("Do you follow a\nspecific diet?")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("This helps us recommend the right recipes.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .modifier(StaggerIn(index: 0, appeared: appeared))

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
            dietRow(option)
              .modifier(StaggerIn(index: offset + 1, appeared: appeared))
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private func dietRow(_ option: DietOption) -> some View {
    let selected = selectedDiet == option.id

    return Button {
      onSelect(option.id)
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        FLIconView(option.icon, size: 22)
          .foregroundStyle(selected ? AppTheme.accent : AppTheme.textSecondary)
          .frame(width: 44, height: 44)
          .background(
            (selected ? AppTheme.accent : AppTheme.oat).opacity(selected ? 0.15 : 0.10),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          )

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(option.title)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)

          Text(option.subtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? AppTheme.accent : AppTheme.oat.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        selected ? AppTheme.accent.opacity(0.08) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(
            selected ? AppTheme.accent.opacity(0.40) : AppTheme.oat.opacity(0.25),
            lineWidth: selected ? 1.5 : 1
          )
      )
      .shadow(
        color: selected ? AppTheme.accent.opacity(0.12) : AppTheme.Shadow.color,
        radius: selected ? 10 : 4,
        x: 0,
        y: selected ? 4 : 2
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .animation(reduceMotion ? nil : AppMotion.selectionPress, value: selected)
  }
}

// MARK: - Step 8: Feature Bridge — Le Chef

struct OnboardingFeatureChefStep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var waveToggle = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: AppTheme.Space.md)

      ZStack {
        RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
          .fill(
            LinearGradient(
              colors: [AppTheme.surface, AppTheme.bgDeep.opacity(0.65)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
          )
          .shadow(color: AppTheme.Shadow.colorDeep, radius: 18, x: 0, y: 12)

        HStack(spacing: AppTheme.Space.lg) {
          phoneCard
            .modifier(StaggerIn(index: 0, appeared: appeared))

          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            chefFeaturePill(icon: "waveform", text: "Voice\nguidance")
              .modifier(StaggerIn(index: 2, appeared: appeared))
            chefFeaturePill(icon: "eye.fill", text: "Sees your\ncooking")
              .modifier(StaggerIn(index: 3, appeared: appeared))
            chefFeaturePill(icon: "rectangle.bottomthird.inset.filled", text: "Live\ndrawer")
              .modifier(StaggerIn(index: 4, appeared: appeared))
          }
        }
        .padding(AppTheme.Space.xl)
      }
      .frame(maxHeight: 310)
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
        .frame(height: AppTheme.Space.xl)

      VStack(spacing: AppTheme.Space.sm) {
        Text("COOK WITH HELP")
          .font(AppTheme.Typography.label)
          .textCase(.uppercase)
          .kerning(1.1)
          .foregroundStyle(AppTheme.accent)
          .modifier(StaggerIn(index: 5, appeared: appeared))

        Text("Get live guidance\nwhile you cook.")
          .font(OnboardingTypography.bridgeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .modifier(StaggerIn(index: 6, appeared: appeared))

        Text(
          "Le Chef watches your prep and talks you through each step in real time."
        )
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(StaggerIn(index: 7, appeared: appeared))
      }
      .frame(maxWidth: 540)
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
        waveToggle = true
      }
    }
  }

  private var phoneCard: some View {
    RoundedRectangle(cornerRadius: 26, style: .continuous)
      .fill(AppTheme.deepOlive)
      .frame(width: 148, height: 264)
      .overlay(
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.accent.opacity(0.18))
            .frame(height: 88)
            .overlay(
              VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text("Le Chef")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(.white.opacity(0.88))
                HStack(spacing: 4) {
                  ForEach(0..<8, id: \.self) { i in
                    Capsule()
                      .fill(i.isMultiple(of: 2) ? AppTheme.accentLight : AppTheme.oat)
                      .frame(
                        width: 5,
                        height: waveToggle
                          ? CGFloat(10 + (i % 4) * 8)
                          : CGFloat(16 + (i % 3) * 9)
                      )
                  }
                }
              }
              .padding(AppTheme.Space.md),
              alignment: .bottomLeading
            )

          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text("1. Stir until glossy")
            Text("2. Lower heat")
            Text("3. Add basil now")
          }
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(.white.opacity(0.82))

          Spacer()
        }
        .padding(AppTheme.Space.md)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .stroke(.white.opacity(0.08), lineWidth: 1)
      )
  }

  private func chefFeaturePill(icon: String, text: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
      Text(text)
        .font(AppTheme.Typography.label)
        .lineLimit(2)
    }
    .foregroundStyle(AppTheme.textPrimary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical + 2)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
  }
}

// MARK: - Step 9: Allergen Safety

struct OnboardingAllergenStep: View {
  let allergenGroupMatchesByID: [String: Set<Int64>]
  let selectedAllergens: Set<Int64>
  let selectedAllergenIngredients: [Ingredient]
  let onToggleGroup: (AllergenGroupDefinition) -> Void
  let onOpenPicker: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectedAllergenChipNamespace
  @State private var appeared = false

  private enum Layout {
    static let allergenGroupChipHeight: CGFloat = 92
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .center, spacing: AppTheme.Space.xs) {
          Text("Allergen safety")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

          Text(
            "Flag what to avoid. FridgeLuck checks every recipe against your list."
          )
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
        }
        .modifier(StaggerIn(index: 0, appeared: appeared))

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: AppTheme.Space.xs),
            GridItem(.flexible(), spacing: AppTheme.Space.xs),
          ],
          spacing: AppTheme.Space.xs
        ) {
          ForEach(AllergenSupport.groups) { group in
            allergenGroupChip(group)
          }
        }
        .modifier(StaggerIn(index: 1, appeared: appeared))

        Button(action: onOpenPicker) {
          Label("Refine Specific Ingredients", systemImage: "magnifyingglass")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .modifier(StaggerIn(index: 2, appeared: appeared))

        FLWaveDivider()

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: "shield.lefthalf.filled")
              .foregroundStyle(AppTheme.sage)
              .font(.system(size: 14, weight: .semibold))
            Text("SELECTED ALLERGENS")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .kerning(1.2)
          }

          Text("\(selectedAllergens.count) selected")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)

          if selectedAllergenIngredients.isEmpty {
            Text("No allergens selected yet.")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
          } else {
            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(Array(selectedAllergenIngredients.prefix(40)), id: \.id) { ingredient in
                Text(ingredient.displayName)
                  .font(AppTheme.Typography.bodySmall)
                  .padding(.horizontal, AppTheme.Space.sm)
                  .padding(.vertical, AppTheme.Space.chipVertical)
                  .background(
                    FLOrganicBlob(seed: ingredient.displayName.hashValue)
                      .fill(AppTheme.accent.opacity(0.12))
                  )
                  .matchedGeometryEffect(
                    id: ingredient.id ?? Int64.min,
                    in: selectedAllergenChipNamespace,
                    properties: .frame
                  )
              }
            }
          }
        }
        .modifier(StaggerIn(index: 3, appeared: appeared))
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private func allergenGroupChip(_ group: AllergenGroupDefinition) -> some View {
    let matchedIDs = allergenGroupMatchesByID[group.id] ?? []
    let selectedCount = selectedAllergens.intersection(matchedIDs).count
    let isFullySelected = !matchedIDs.isEmpty && selectedCount == matchedIDs.count
    let isPartiallySelected = selectedCount > 0 && !isFullySelected
    let isSelected = isFullySelected || isPartiallySelected

    return Button {
      onToggleGroup(group)
    } label: {
      HStack(spacing: AppTheme.Space.xs) {
        FLIconView(group.icon.source, size: 22)
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(group.title)
            .font(AppTheme.Typography.label)
            .lineLimit(1)
            .foregroundStyle(AppTheme.textPrimary)
          Text(isSelected ? "\(selectedCount) selected" : group.subtitle)
            .font(AppTheme.Typography.labelSmall)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 34, alignment: .topLeading)
        Spacer(minLength: 0)
        Image(
          systemName: isFullySelected
            ? "checkmark.circle.fill" : (isPartiallySelected ? "minus.circle.fill" : "circle"))
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.sm)
      .frame(
        maxWidth: .infinity,
        minHeight: Layout.allergenGroupChipHeight,
        maxHeight: Layout.allergenGroupChipHeight,
        alignment: .leading
      )
      .background(
        isSelected ? AppTheme.accent.opacity(0.14) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .opacity(matchedIDs.isEmpty ? 0.75 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(matchedIDs.isEmpty)
  }
}

// MARK: - Step 10: Apple Health Value (Visual)

struct OnboardingAppleHealthValueStep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.xl) {
        Spacer()
          .frame(height: AppTheme.Space.xs)

        ZStack {
          RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
            .fill(
              LinearGradient(
                colors: [AppTheme.surface, AppTheme.bgDeep.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
                .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: AppTheme.Shadow.colorDeep, radius: 18, x: 0, y: 12)

          VStack(spacing: AppTheme.Space.lg) {
            HStack(spacing: AppTheme.Space.sm) {
              nutritionMini(value: "1,699", label: "kcal", color: AppTheme.accent)
              nutritionMini(value: "141g", label: "protein", color: AppTheme.chartProtein)
              nutritionMini(value: "47g", label: "fat", color: AppTheme.chartFat)
            }

            HStack(spacing: AppTheme.Space.sm) {
              ZStack {
                Circle()
                  .fill(
                    LinearGradient(
                      colors: [Color.red.opacity(0.15), Color.pink.opacity(0.08)],
                      startPoint: .topLeading,
                      endPoint: .bottomTrailing
                    )
                  )
                  .frame(width: 38, height: 38)
                Image(systemName: "heart.fill")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(.red)
              }

              VStack(alignment: .leading, spacing: 2) {
                Text("Apple Health")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.textPrimary)
                Text("Syncing daily nutrition")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }

              Spacer()

              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.sage)
                .font(.system(size: 18))
            }
            .padding(AppTheme.Space.md)
            .background(
              AppTheme.surface,
              in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .stroke(AppTheme.sage.opacity(0.22), lineWidth: 1)
            )
          }
          .padding(AppTheme.Space.lg)
        }
        .padding(.horizontal, AppTheme.Space.page)
        .modifier(StaggerIn(index: 0, appeared: appeared))

        VStack(spacing: AppTheme.Space.sm) {
          Text("KEEP EVERYTHING IN SYNC")
            .font(AppTheme.Typography.label)
            .textCase(.uppercase)
            .kerning(1.1)
            .foregroundStyle(AppTheme.accent)
            .modifier(StaggerIn(index: 1, appeared: appeared))

          Text("Connect Apple Health for\neffortless tracking.")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(StaggerIn(index: 2, appeared: appeared))

          Text("Keep your nutrition history in one place without extra logging.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .modifier(StaggerIn(index: 3, appeared: appeared))
        }

        VStack(spacing: AppTheme.Space.sm) {
          healthBenefit(
            icon: "square.and.arrow.up.fill", title: "Save meals automatically", index: 4)
          healthBenefit(
            icon: "chart.bar.fill", title: "See your daily nutrition totals", index: 5)
          healthBenefit(
            icon: "shield.lefthalf.filled", title: "You stay in control of what gets shared",
            index: 6)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.xl)
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private func nutritionMini(value: String, label: String, color: Color) -> some View {
    VStack(spacing: AppTheme.Space.xs) {
      Text(value)
        .font(AppTheme.Typography.dataMedium)
        .foregroundStyle(color)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.md)
    .background(
      color.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
  }

  private func healthBenefit(icon: String, title: String, index: Int) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(AppTheme.accent)
        .frame(width: 42, height: 42)
        .background(
          AppTheme.accent.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )

      Text(title)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
    .modifier(StaggerIn(index: index, appeared: appeared))
  }
}

// MARK: - Step 11: Apple Health Permission

struct OnboardingAppleHealthPermissionStep: View {
  let status: AppPermissionStatus
  let isRequestInFlight: Bool
  let didChooseSkip: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 80)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.sm) {
          statusBadge
            .modifier(StaggerIn(index: 0, appeared: appeared))

          Text(title)
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .modifier(StaggerIn(index: 1, appeared: appeared))

          Text(message)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(StaggerIn(index: 2, appeared: appeared))
        }

        VStack(spacing: AppTheme.Space.sm) {
          permissionNote(
            "Writes the meals you log in FridgeLuck to Apple Health.", index: 3)
          permissionNote(
            status == .denied
              ? "Use Settings to turn access back on, then return here."
              : "You can manage the connection later in Settings.",
            index: 4
          )
        }

        if isRequestInFlight {
          ProgressView()
            .controlSize(.small)
            .tint(AppTheme.accent)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 150_000_000)
      appeared = true
    }
  }

  private var title: String {
    switch status {
    case .authorized:
      return "Apple Health is connected."
    case .unavailable:
      return "Apple Health is not available here."
    case .denied:
      return "Apple Health can stay off for now."
    default:
      return "Connect Apple Health."
    }
  }

  private var message: String {
    switch status {
    case .authorized:
      return "FridgeLuck can now keep your meals in sync."
    case .unavailable:
      return "You can still use every core part of FridgeLuck without it."
    case .denied:
      return didChooseSkip
        ? "You chose to skip this for now. You can connect later in Settings."
        : "If you do not want to connect right now, skip this step and keep going."
    default:
      return
        "Connect once so FridgeLuck can save your meal logs and read your daily nutrition totals automatically."
    }
  }

  private var statusBadge: some View {
    let label: String
    let tint: Color

    switch status {
    case .authorized:
      label = "Connected"
      tint = AppTheme.sage
    case .denied:
      label = "Optional"
      tint = AppTheme.oat
    case .unavailable:
      label = "Unavailable"
      tint = AppTheme.textSecondary
    default:
      label = "Optional"
      tint = AppTheme.accent
    }

    return Text(label)
      .font(AppTheme.Typography.label)
      .foregroundStyle(tint)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(tint.opacity(0.12), in: Capsule())
  }

  private func permissionNote(_ text: String, index: Int) -> some View {
    HStack(alignment: .top, spacing: AppTheme.Space.sm) {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(AppTheme.accent)
        .padding(.top, 4)

      Text(text)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

      Spacer()
    }
    .modifier(StaggerIn(index: index, appeared: appeared))
  }
}

// MARK: - Step 12: Setup Bridge (Animated)

struct OnboardingSetupBridgeStep: View {
  let displayName: String
  let goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var progress: Double = 0
  @State private var messageIndex = 0
  @State private var appeared = false

  private let messages = [
    "Calibrating recipes...",
    "Setting allergen filters...",
    "Connecting preferences...",
    "Almost ready...",
  ]

  private let checklistItems = [
    "Calories",
    "Macros",
    "Allergens",
    "Recipes",
    "Health Score",
  ]

  var body: some View {
    VStack(spacing: AppTheme.Space.xl) {
      Spacer()

      ZStack {
        Circle()
          .stroke(AppTheme.oat.opacity(0.18), lineWidth: 6)
          .frame(width: 140, height: 140)

        Circle()
          .trim(from: 0, to: progress)
          .stroke(
            LinearGradient(
              colors: [AppTheme.accent, AppTheme.accentLight],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            style: StrokeStyle(lineWidth: 6, lineCap: .round)
          )
          .frame(width: 140, height: 140)
          .rotationEffect(.degrees(-90))

        Text("\(Int(progress * 100))%")
          .font(.system(size: 38, weight: .bold, design: .serif))
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText(value: progress))
          .animation(reduceMotion ? nil : AppMotion.quick, value: progress)
      }
      .modifier(StaggerIn(index: 0, appeared: appeared))

      VStack(spacing: AppTheme.Space.sm) {
        Text("Building your FridgeLuck setup")
          .font(OnboardingTypography.sectionTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
          .modifier(StaggerIn(index: 1, appeared: appeared))

        Text(messages[messageIndex])
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .contentTransition(.opacity)
          .animation(reduceMotion ? nil : AppMotion.messageCrossfade, value: messageIndex)
          .modifier(StaggerIn(index: 2, appeared: appeared))
      }
      .padding(.horizontal, AppTheme.Space.page)

      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        ForEach(Array(checklistItems.enumerated()), id: \.offset) { index, item in
          let isComplete =
            progress > Double(index + 1) / Double(checklistItems.count + 1)
          HStack(spacing: AppTheme.Space.sm) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 16))
              .foregroundStyle(isComplete ? AppTheme.sage : AppTheme.oat.opacity(0.4))
              .animation(reduceMotion ? nil : AppMotion.chipToggle, value: isComplete)
            Text(item)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(isComplete ? AppTheme.textPrimary : AppTheme.textSecondary)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.xxl)
      .modifier(StaggerIn(index: 3, appeared: appeared))

      Spacer()
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 80_000_000)
      appeared = true

      guard !reduceMotion else {
        progress = 1
        messageIndex = messages.count - 1
        return
      }

      for step in 1...20 {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        withAnimation(AppMotion.quick) {
          progress = Double(step) / 20.0
        }
        let newIdx = min(step / 5, messages.count - 1)
        if newIdx != messageIndex {
          messageIndex = newIdx
        }
      }
    }
  }
}

// MARK: - Step 13: Handoff (Celebration)

struct OnboardingHandoffStep: View {
  let displayName: String
  let goal: HealthGoal
  let dailyCalories: Int
  let selectedDiet: String
  let allergenCount: Int
  let healthConnected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var showConfetti = false

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        Spacer()
          .frame(maxHeight: 60)

        VStack(spacing: AppTheme.Space.xl) {
          ZStack {
            Circle()
              .fill(
                RadialGradient(
                  colors: [AppTheme.sage.opacity(0.2), AppTheme.sage.opacity(0.04)],
                  center: .center,
                  startRadius: 18,
                  endRadius: 90
                )
              )
              .frame(width: 160, height: 160)

            Image(systemName: "party.popper.fill")
              .font(.system(size: 56, weight: .semibold))
              .foregroundStyle(AppTheme.sage)
          }
          .scaleEffect(appeared ? 1 : 0.5)
          .opacity(appeared ? 1 : 0)
          .animation(reduceMotion ? nil : AppMotion.celebration, value: appeared)

          VStack(spacing: AppTheme.Space.sm) {
            Text("You're ready,\n\(displayName.isEmpty ? "friend" : displayName).")
              .font(OnboardingTypography.welcomeTitle)
              .foregroundStyle(AppTheme.textPrimary)
              .multilineTextAlignment(.center)
              .modifier(StaggerIn(index: 1, appeared: appeared))

            Text(
              "Your kitchen profile is all set. Let's take a quick tour so everything feels familiar."
            )
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .modifier(StaggerIn(index: 2, appeared: appeared))
          }
          .padding(.horizontal, AppTheme.Space.page)

          VStack(spacing: AppTheme.Space.xs) {
            summaryPill(text: "\(goal.displayName) · \(dailyCalories) kcal")
            if selectedDiet != "classic" {
              summaryPill(text: selectedDiet.capitalized)
            }
            if allergenCount > 0 {
              summaryPill(text: "\(allergenCount) allergens flagged")
            }
            if healthConnected {
              summaryPill(text: "Apple Health connected", tint: AppTheme.sage)
            }
          }
          .modifier(StaggerIn(index: 3, appeared: appeared))
        }

        Spacer()
      }

      if showConfetti {
        ConfettiOverlay(particleCount: 50)
          .allowsHitTesting(false)
      }
    }
    .task {
      guard !appeared else { return }
      try? await Task.sleep(nanoseconds: 200_000_000)
      appeared = true
      if !reduceMotion {
        try? await Task.sleep(nanoseconds: 400_000_000)
        showConfetti = true
      }
    }
  }

  private func summaryPill(text: String, tint: Color = AppTheme.accent) -> some View {
    Text(text)
      .font(AppTheme.Typography.label)
      .foregroundStyle(tint)
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(tint.opacity(0.10), in: Capsule())
  }
}

// MARK: - Progress Bar

struct OnboardingProgressBar: View {
  let progress: Double
  let reduceMotion: Bool

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(AppTheme.oat.opacity(0.18))
          .frame(height: 5)

        Capsule()
          .fill(
            LinearGradient(
              colors: [AppTheme.accent, AppTheme.accentLight],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: geo.size.width * max(0, min(1, progress)), height: 5)
          .shadow(color: AppTheme.accent.opacity(0.25), radius: 3, x: 2, y: 0)
          .animation(reduceMotion ? nil : AppMotion.progressBar, value: progress)
      }
    }
    .frame(height: 5)
    .padding(.horizontal, AppTheme.Space.page)
  }
}

// MARK: - Back Button

struct OnboardingBackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(AppTheme.textSecondary)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Onboarding Footer

struct OnboardingFooter: View {
  let isSaving: Bool
  let isTransitioning: Bool
  let primaryButtonTitle: String
  let primaryButtonIcon: String
  let secondaryButtonTitle: String?
  let secondaryButtonIcon: String?
  let onPrimaryAction: () -> Void
  let onSecondaryAction: (() -> Void)?

  var body: some View {
    VStack(spacing: AppTheme.Space.xs) {
      if let secondaryButtonTitle, let onSecondaryAction {
        FLSecondaryButton(
          secondaryButtonTitle,
          systemImage: secondaryButtonIcon,
          isEnabled: !isSaving && !isTransitioning,
          action: onSecondaryAction
        )
        .buttonRepeatBehavior(.disabled)
      }

      FLPrimaryButton(
        primaryButtonTitle,
        systemImage: primaryButtonIcon,
        isEnabled: !isSaving && !isTransitioning,
        labelAnimation: .subtleBlend
      ) {
        onPrimaryAction()
      }
      .buttonRepeatBehavior(.disabled)

      if isSaving {
        ProgressView()
          .controlSize(.small)
          .tint(AppTheme.accent)
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.vertical, AppTheme.Space.sm)
    .background(AppTheme.bg)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(AppTheme.oat.opacity(0.25))
        .frame(height: 1)
    }
  }
}
