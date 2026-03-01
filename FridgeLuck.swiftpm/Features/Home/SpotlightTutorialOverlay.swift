import SwiftUI

// MARK: - Step Model

struct SpotlightStep: Identifiable {
  let id: String
  let anchorID: String?
  let icon: String
  let title: String
  let message: String
}

extension SpotlightStep {
  static let onboarding: [SpotlightStep] = [
    SpotlightStep(
      id: "welcome",
      anchorID: nil,
      icon: "sparkles",
      title: "Meet FridgeLuck",
      message:
        "Most apps track what you\u{2019}ve already eaten. I\u{2019}m different \u{2014} I help you decide what to cook next using what\u{2019}s already in your fridge."
    ),
    SpotlightStep(
      id: "setup",
      anchorID: "progressView",
      icon: "rectangle.stack",
      title: "Your Guided Setup",
      message:
        "Each step teaches a different way I help you eat smarter, save money, and reduce waste. Complete them all to unlock your full dashboard."
    ),
    SpotlightStep(
      id: "personalize",
      anchorID: "quest_0",
      icon: "person.crop.circle.badge.checkmark",
      title: "Personalized to You",
      message:
        "Tell me your goals, dietary needs, and allergens. I\u{2019}ll tailor every recipe so it actually fits your life \u{2014} not the other way around."
    ),
    SpotlightStep(
      id: "ready",
      anchorID: nil,
      icon: "arrow.right.circle",
      title: "Let\u{2019}s Get Started",
      message:
        "Complete these quick steps to unlock your dashboard with personalized insights, cooking streaks, and recipes built around what you have."
    ),
  ]
}

// MARK: - Preference Key

struct SpotlightAnchorKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

extension View {
  func spotlightAnchor(_ id: String) -> some View {
    background(
      GeometryReader { geo in
        Color.clear.preference(
          key: SpotlightAnchorKey.self,
          value: [id: geo.frame(in: .global)]
        )
      }
    )
  }
}

// MARK: - Overlay

struct SpotlightTutorialOverlay: View {
  let steps: [SpotlightStep]
  let anchors: [String: CGRect]
  @Binding var isPresented: Bool

  @State private var stepIndex = 0
  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: SpotlightStep { steps[stepIndex] }
  private var isLast: Bool { stepIndex >= steps.count - 1 }

  private var highlightRect: CGRect? {
    guard let aid = step.anchorID else { return nil }
    return anchors[aid]
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        dimmingLayer
        highlightBorder
        tooltipCard(in: geo)
        skipLabel(in: geo)
      }
    }
    .ignoresSafeArea()
    .contentShape(Rectangle())
    .onTapGesture { advance() }
    .opacity(appeared ? 1 : 0)
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
        appeared = true
      }
    }
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - Dimming

  @ViewBuilder
  private var dimmingLayer: some View {
    let pad: CGFloat = 10
    let cr: CGFloat = 14

    if let rect = highlightRect {
      Color.black.opacity(0.68)
        .reverseMask {
          RoundedRectangle(cornerRadius: cr, style: .continuous)
            .frame(width: rect.width + pad * 2, height: rect.height + pad * 2)
            .position(x: rect.midX, y: rect.midY)
        }
        .animation(
          reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
          value: stepIndex
        )
    } else {
      Color.black.opacity(0.72)
    }
  }

  @ViewBuilder
  private var highlightBorder: some View {
    if let rect = highlightRect {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.white.opacity(0.22), lineWidth: 1.5)
        .frame(width: rect.width + 20, height: rect.height + 20)
        .position(x: rect.midX, y: rect.midY)
        .animation(
          reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
          value: stepIndex
        )
    }
  }

  // MARK: - Tooltip

  private func tooltipCard(in geo: GeometryProxy) -> some View {
    let screenH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
    let y = tooltipY(screenHeight: screenH)

    return VStack(spacing: AppTheme.Space.md) {
      Image(systemName: step.icon)
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(AppTheme.accent.opacity(0.85), in: Circle())

      VStack(spacing: AppTheme.Space.xs) {
        Text(step.title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)

        Text(step.message)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(.white.opacity(0.76))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        stepIndicator
        Spacer()
        navButton
      }
      .padding(.top, AppTheme.Space.xxs)
    }
    .padding(AppTheme.Space.lg)
    .frame(maxWidth: min(geo.size.width - 48, 340))
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        .fill(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 15)
    .position(x: geo.size.width / 2, y: y)
    .animation(
      reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82),
      value: stepIndex
    )
  }

  private var stepIndicator: some View {
    HStack(spacing: 5) {
      ForEach(0..<steps.count, id: \.self) { i in
        Capsule()
          .fill(i == stepIndex ? Color.white : Color.white.opacity(0.28))
          .frame(width: i == stepIndex ? 18 : 6, height: 6)
          .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75),
            value: stepIndex
          )
      }
    }
  }

  @ViewBuilder
  private var navButton: some View {
    if isLast {
      Button {
        dismissOverlay()
      } label: {
        Text("Let\u{2019}s go")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .background(.white, in: Capsule())
      }
      .buttonStyle(.plain)
    } else {
      Button {
        advance()
      } label: {
        HStack(spacing: 4) {
          Text("Next")
          Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.16), in: Capsule())
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Skip

  private func skipLabel(in geo: GeometryProxy) -> some View {
    VStack {
      HStack {
        Spacer()
        Button {
          dismissOverlay()
        } label: {
          Text("Skip")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
      }
      .padding(.top, geo.safeAreaInsets.top + 8)
      .padding(.trailing, 16)
      Spacer()
    }
  }

  // MARK: - Positioning

  private func tooltipY(screenHeight: CGFloat) -> CGFloat {
    guard let rect = highlightRect else {
      return screenHeight / 2
    }
    let cardH: CGFloat = 260
    let gap: CGFloat = 24
    let below = rect.maxY + gap + cardH / 2
    let above = rect.minY - gap - cardH / 2

    if below + cardH / 2 < screenHeight - 40 { return below }
    if above - cardH / 2 > 40 { return above }
    return screenHeight / 2
  }

  // MARK: - Actions

  private func advance() {
    guard !isLast else {
      dismissOverlay()
      return
    }
    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) {
      stepIndex += 1
    }
  }

  private func dismissOverlay() {
    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) {
      appeared = false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
      isPresented = false
    }
  }
}

// MARK: - Reverse Mask

extension View {
  fileprivate func reverseMask<M: View>(@ViewBuilder _ content: () -> M) -> some View {
    mask {
      Rectangle()
        .ignoresSafeArea()
        .overlay { content().blendMode(.destinationOut) }
    }
  }
}
