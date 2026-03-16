import SwiftUI

// MARK: - Stat Display

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
        .foregroundStyle(useDarkStyle ? AppTheme.surface.opacity(0.65) : AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Analyzing Pulse Animation

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

// MARK: - Star Rating

struct FLStarRating: View {
  @Binding var rating: Int
  var maxRating: Int = 5
  var size: CGFloat = 28

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var animatingStars: Set<Int> = []

  var body: some View {
    HStack(spacing: AppTheme.Space.xs) {
      ForEach(1...maxRating, id: \.self) { star in
        Button {
          let newRating = star == rating ? 0 : star
          withAnimation(reduceMotion ? nil : AppMotion.starBounce) {
            rating = newRating
          }
          if !reduceMotion {
            animatingStars.insert(star)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              animatingStars.remove(star)
            }
          }
        } label: {
          Image(systemName: star <= rating ? "star.fill" : "star")
            .font(.system(size: size))
            .foregroundStyle(star <= rating ? AppTheme.accent : AppTheme.oat.opacity(0.4))
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: star <= rating)
            .scaleEffect(animatingStars.contains(star) ? 1.25 : 1.0)
            .animation(reduceMotion ? nil : AppMotion.starBounce, value: animatingStars)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Serving Stepper

struct FLServingStepper: View {
  @Binding var servings: Int
  var range: ClosedRange<Int> = 1...8
  var label: String = "Servings"

  var body: some View {
    HStack(spacing: AppTheme.Space.md) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(label)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
        Text("\(servings) serving\(servings == 1 ? "" : "s")")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())
      }

      Spacer()

      HStack(spacing: AppTheme.Space.sm) {
        stepperButton(systemImage: "minus", enabled: servings > range.lowerBound) {
          withAnimation(AppMotion.quick) { servings -= 1 }
        }

        Text("\(servings)")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .frame(width: 32)
          .contentTransition(.numericText())

        stepperButton(systemImage: "plus", enabled: servings < range.upperBound) {
          withAnimation(AppMotion.quick) { servings += 1 }
        }
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surfaceMuted.opacity(0.5),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
  }

  private func stepperButton(systemImage: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(enabled ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3))
        .frame(width: 36, height: 36)
        .background(
          enabled ? AppTheme.accent.opacity(0.12) : AppTheme.surfaceMuted,
          in: Circle()
        )
        .animation(.default, value: enabled)
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(!enabled)
  }
}

// MARK: - Macro Ring

struct FLMacroRing: View {
  let proteinPct: Double
  let carbsPct: Double
  let fatPct: Double
  var size: CGFloat = 120
  var lineWidth: CGFloat = 12

  var body: some View {
    ZStack {
      Circle()
        .stroke(AppTheme.surfaceMuted, lineWidth: lineWidth)

      Circle()
        .trim(from: 0, to: proteinPct + carbsPct + fatPct)
        .stroke(AppTheme.accentLight, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))

      Circle()
        .trim(from: 0, to: proteinPct + carbsPct)
        .stroke(AppTheme.oat, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))

      Circle()
        .trim(from: 0, to: proteinPct)
        .stroke(AppTheme.sage, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: size, height: size)
  }
}
