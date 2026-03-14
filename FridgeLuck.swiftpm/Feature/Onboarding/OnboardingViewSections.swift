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
}

struct OnboardingStorySlide: Identifiable {
  enum Artwork {
    case hero
    case scanPantry
    case pantryLoop
    case leChef
    case trust
  }

  let id: String
  let eyebrow: String
  let title: String
  let body: String
  let caption: String
  let artwork: Artwork

  static let defaultDeck: [OnboardingStorySlide] = [
    .init(
      id: "hero",
      eyebrow: "Welcome",
      title: "Turn what you have into meals you can trust.",
      body:
        "FridgeLuck helps you understand what is in your kitchen, decide what to cook, and stay confident that the suggestions fit your life.",
      caption: "Simple enough for a first-time cook. Smart enough to keep up every day.",
      artwork: .hero
    ),
    .init(
      id: "scan",
      eyebrow: "See Your Kitchen",
      title: "Scan your fridge or pantry in seconds.",
      body:
        "Point your camera at what you already have and FridgeLuck turns the mess into ingredients you can actually cook with.",
      caption: "No spreadsheets. No typing every item by hand.",
      artwork: .scanPantry
    ),
    .init(
      id: "pantry",
      eyebrow: "Stay Updated",
      title: "Keep a virtual pantry without the busywork.",
      body:
        "As your groceries change, FridgeLuck keeps your kitchen picture current so recipes keep matching what is really there.",
      caption: "Less waste, fewer forgotten ingredients, faster decisions.",
      artwork: .pantryLoop
    ),
    .init(
      id: "lechef",
      eyebrow: "Cook With Help",
      title: "Get live kitchen help while you cook.",
      body:
        "Le Chef guides you in real time so the app feels more like a calm cooking partner than a static recipe page.",
      caption: "Hands busy. Eyes on the pan. Guidance when you need it.",
      artwork: .leChef
    ),
    .init(
      id: "trust",
      eyebrow: "Stay In Control",
      title: "You make the final call.",
      body:
        "FridgeLuck takes accuracy seriously. It asks when something looks uncertain and gets better around your choices over time.",
      caption: "Helpful AI, with human control where it matters.",
      artwork: .trust
    ),
  ]
}

struct OnboardingStoryStep: View {
  let slides: [OnboardingStorySlide]
  @Binding var currentPage: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: AppTheme.Space.sm)

      TabView(selection: $currentPage) {
        ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
          storyPage(slide)
            .tag(index)
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .animation(reduceMotion ? nil : AppMotion.pageTurn, value: currentPage)

      HStack(spacing: AppTheme.Space.xs) {
        ForEach(Array(slides.indices), id: \.self) { index in
          Capsule()
            .fill(index == currentPage ? AppTheme.accent : AppTheme.oat.opacity(0.28))
            .frame(width: index == currentPage ? 20 : 8, height: 8)
            .animation(reduceMotion ? nil : AppMotion.quick, value: currentPage)
        }
      }
      .padding(.bottom, AppTheme.Space.sm)
    }
  }

  private func storyPage(_ slide: OnboardingStorySlide) -> some View {
    VStack(spacing: AppTheme.Space.lg) {
      OnboardingStoryArtworkCard(artwork: slide.artwork)
        .frame(maxHeight: 360)

      VStack(spacing: AppTheme.Space.sm) {
        Text(slide.eyebrow)
          .font(AppTheme.Typography.label)
          .textCase(.uppercase)
          .kerning(1.1)
          .foregroundStyle(AppTheme.accent)

        Text(slide.title)
          .font(OnboardingTypography.welcomeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text(slide.body)
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Text(slide.caption)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.9))
          .multilineTextAlignment(.center)
          .padding(.top, AppTheme.Space.xxs)
      }
      .frame(maxWidth: 540)

      Spacer(minLength: 0)
    }
  }
}

private struct OnboardingStoryArtworkCard: View {
  let artwork: OnboardingStorySlide.Artwork

  var body: some View {
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

      switch artwork {
      case .hero:
        heroArtwork
      case .scanPantry:
        scenarioArtwork(
          image: DemoScanService.loadScenarioImage(for: .asianStirFry),
          label: "Snap your shelf",
          accent: AppTheme.accent
        )
      case .pantryLoop:
        scenarioArtwork(
          image: DemoScanService.loadScenarioImage(for: .mediterraneanLunch),
          label: "Keep your pantry current",
          accent: AppTheme.sage
        )
      case .leChef:
        leChefArtwork
      case .trust:
        trustArtwork
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, AppTheme.Space.md)
  }

  private var heroArtwork: some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [AppTheme.heroLight, AppTheme.accentLight],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 142, height: 142)
          .blur(radius: 10)

        if UIImage(named: "FridgeLuckLogo") != nil {
          Image("FridgeLuckLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 92, height: 92)
        } else {
          Image(systemName: "refrigerator.fill")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }
      }

      HStack(spacing: AppTheme.Space.sm) {
        featurePill(icon: "camera.macro", text: "Scan")
        featurePill(icon: "fork.knife", text: "Cook")
        featurePill(icon: "heart.text.square", text: "Track")
      }
    }
    .padding(AppTheme.Space.xl)
  }

  private func scenarioArtwork(image: UIImage?, label: String, accent: Color) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(height: 238)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
              .stroke(.white.opacity(0.22), lineWidth: 1)
          )
      }

      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "sparkles")
          .foregroundStyle(accent)
        Text(label)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(AppTheme.Space.lg)
  }

  private var leChefArtwork: some View {
    HStack(spacing: AppTheme.Space.lg) {
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(AppTheme.deepOlive)
        .frame(width: 154, height: 276)
        .overlay(
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(AppTheme.accent.opacity(0.18))
              .frame(height: 92)
              .overlay(
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                  Text("Le Chef")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(.white.opacity(0.85))
                  HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { index in
                      Capsule()
                        .fill(index.isMultiple(of: 2) ? AppTheme.accentLight : AppTheme.oat)
                        .frame(width: 5, height: CGFloat(16 + (index % 3) * 9))
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

      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        featurePill(icon: "waveform", text: "Voice guidance")
        featurePill(icon: "eye.fill", text: "Sees your cooking")
        featurePill(icon: "rectangle.bottomthird.inset.filled", text: "Live drawer")
      }
    }
    .padding(AppTheme.Space.xl)
  }

  private var trustArtwork: some View {
    VStack(spacing: AppTheme.Space.lg) {
      VStack(spacing: AppTheme.Space.sm) {
        trustRow(icon: "checkmark.seal.fill", title: "Confident picks", tint: AppTheme.sage)
        trustRow(icon: "questionmark.circle.fill", title: "Ask when unsure", tint: AppTheme.oat)
        trustRow(icon: "brain.head.profile", title: "Learns your choices", tint: AppTheme.accent)
      }
      .padding(AppTheme.Space.lg)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
          .fill(AppTheme.surface)
      )
    }
    .padding(AppTheme.Space.xl)
  }

  private func trustRow(icon: String, title: String, tint: Color) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      Text(title)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()
    }
  }

  private func featurePill(icon: String, text: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
      Text(text)
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textPrimary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(AppTheme.surface, in: Capsule())
    .overlay(Capsule().stroke(AppTheme.oat.opacity(0.2), lineWidth: 1))
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
          .frame(height: 4)

        Capsule()
          .fill(AppTheme.accent)
          .frame(width: geo.size.width * max(0, min(1, progress)), height: 4)
          .animation(reduceMotion ? nil : AppMotion.progressBar, value: progress)
      }
    }
    .frame(height: 4)
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

// MARK: - Step 1: Name Input

struct OnboardingNameStep: View {
  @Binding var displayName: String
  @FocusState.Binding var isNameFocused: Bool
  let validationMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 80)

      VStack(spacing: AppTheme.Space.lg) {
        Text("What's your name?")
          .font(OnboardingTypography.sectionTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text("We'll use this to personalize your experience.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)

        TextField("Your name", text: $displayName)
          .font(.system(size: 24, weight: .medium, design: .serif))
          .multilineTextAlignment(.center)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .focused($isNameFocused)
          .padding(.vertical, AppTheme.Space.md)
          .background(
            VStack {
              Spacer()
              Rectangle()
                .fill(AppTheme.accent.opacity(0.35))
                .frame(height: 2)
            }
          )
          .padding(.horizontal, AppTheme.Space.xl)

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
  }
}

// MARK: - Step 2: Welcome

struct OnboardingWelcomeStep: View {
  let displayName: String

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 100)

      VStack(spacing: AppTheme.Space.lg) {
        Text("Welcome, \(displayName)!")
          .font(OnboardingTypography.welcomeTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        VStack(spacing: AppTheme.Space.md) {
          Text("Let's set up your kitchen profile so\nFridgeLuck can work its magic.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: AppTheme.Space.md) {
            welcomeFeature(icon: "fork.knife", text: "Personalized recipes")
            welcomeFeature(icon: "shield.lefthalf.filled", text: "Allergen safety")
            welcomeFeature(icon: "chart.bar", text: "Nutrition tracking")
          }
          .padding(.top, AppTheme.Space.md)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }

  private func welcomeFeature(icon: String, text: String) -> some View {
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
  }
}

// MARK: - Step 3: Age (Horizontal Scroll Ruler)

struct OnboardingAgeStep: View {
  @Binding var age: Int
  let reduceMotion: Bool

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

        HorizontalScrollRuler(
          value: $age,
          range: 13...100,
          reduceMotion: reduceMotion
        )
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
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

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(options) { option in
            goalCard(option)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
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

// MARK: - Step 5: Daily Calorie Target

struct OnboardingCalorieStep: View {
  @Binding var dailyCalories: Int
  let goal: HealthGoal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

          Text("Adjust to match your lifestyle. We've pre-filled based on your goal.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

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
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }
}

// MARK: - Step 6: Diet Selection (Single-select)

struct OnboardingDietStep: View {
  let options: [DietOption]
  let selectedDiet: String
  let onSelect: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(options) { option in
            dietRow(option)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xl)
      .padding(.bottom, AppTheme.Space.xl)
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

// MARK: - Step 7: Allergen Safety

struct OnboardingAllergenStep: View {
  let allergenGroupMatchesByID: [String: Set<Int64>]
  let selectedAllergens: Set<Int64>
  let selectedAllergenIngredients: [Ingredient]
  let onToggleGroup: (AllergenGroupDefinition) -> Void
  let onOpenPicker: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectedAllergenChipNamespace

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
            "Start with the Big 10 here. Open the detail picker only if you want exact ingredient-level control."
          )
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
        }

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

        Button(action: onOpenPicker) {
          Label("Refine Specific Ingredients", systemImage: "magnifyingglass")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)

        FLWaveDivider()

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("SELECTED ALLERGENS")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

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
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
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

// MARK: - Apple Health

struct OnboardingAppleHealthValueStep: View {
  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.xl) {
        Spacer()
          .frame(height: AppTheme.Space.sm)

        ZStack {
          Circle()
            .fill(AppTheme.accent.opacity(0.10))
            .frame(width: 170, height: 170)

          Image(systemName: "heart.text.square.fill")
            .font(.system(size: 62, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }

        VStack(spacing: AppTheme.Space.sm) {
          Text("Connect Apple Health")
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Keep your nutrition history in one place without extra logging.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.sm) {
          healthBenefit(icon: "square.and.arrow.up.fill", title: "Save meals automatically")
          healthBenefit(icon: "chart.bar.fill", title: "See your food story more clearly")
          healthBenefit(
            icon: "shield.lefthalf.filled", title: "You stay in control of what gets shared")
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.xl)
    }
  }

  private func healthBenefit(icon: String, title: String) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(AppTheme.accent)
        .frame(width: 42, height: 42)
        .background(
          AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text(title)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
  }
}

struct OnboardingAppleHealthPermissionStep: View {
  let status: AppPermissionStatus
  let isRequestInFlight: Bool
  let didChooseSkip: Bool

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 80)

      VStack(spacing: AppTheme.Space.xl) {
        VStack(spacing: AppTheme.Space.sm) {
          statusBadge

          Text(title)
            .font(OnboardingTypography.sectionTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text(message)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(spacing: AppTheme.Space.sm) {
          permissionNote("Writes the meals you log in FridgeLuck to Apple Health.")
          permissionNote("Reads your nutrition totals so tracking starts connected from day one.")
          permissionNote(
            status == .denied
              ? "Use Settings to turn access back on, then return here."
              : "You can manage the connection later in Settings after setup."
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
        ? "You chose to skip this for now. You can still finish setup and connect later in Settings."
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

  private func permissionNote(_ text: String) -> some View {
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
  }
}

struct OnboardingSetupBridgeStep: View {
  let displayName: String
  let goal: HealthGoal

  var body: some View {
    VStack(spacing: AppTheme.Space.xl) {
      Spacer()

      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)

      VStack(spacing: AppTheme.Space.sm) {
        Text("Building your FridgeLuck setup")
          .font(OnboardingTypography.sectionTitle)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text(copy)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }

  private var copy: String {
    let firstName = displayName.isEmpty ? "you" : displayName
    switch goal {
    case .general:
      return "Pulling together everyday recommendations for \(firstName)."
    case .weightLoss:
      return "Shaping lighter, more goal-aware picks for \(firstName)."
    case .muscleGain:
      return "Setting up protein-forward recommendations for \(firstName)."
    case .maintenance:
      return "Balancing steady, repeatable meal picks for \(firstName)."
    }
  }
}

struct OnboardingHandoffStep: View {
  let displayName: String

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(maxHeight: 70)

      VStack(spacing: AppTheme.Space.xl) {
        ZStack {
          Circle()
            .fill(AppTheme.sage.opacity(0.14))
            .frame(width: 152, height: 152)

          Image(systemName: "party.popper.fill")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(AppTheme.sage)
        }

        VStack(spacing: AppTheme.Space.sm) {
          Text("You're ready, \(displayName.isEmpty ? "friend" : displayName).")
            .font(OnboardingTypography.welcomeTitle)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text(
            "Next, FridgeLuck will walk you through the app with a guided demo so everything feels familiar before your first real scan."
          )
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AppTheme.Space.page)
      }

      Spacer()
    }
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
