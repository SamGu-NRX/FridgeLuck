import SwiftUI

struct DemoModeHeaderSection: View {
  let appeared: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text("Try FridgeLuck")
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Text("Pick a pre-stocked fridge to explore, or snap your own photo.")
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
  }
}

struct DemoModeHowItWorksCallout: View {
  let appeared: Bool
  let reduceMotion: Bool
  let isFirstVisit: Bool

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "lightbulb.min.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(AppTheme.oat)
        .frame(width: 32, height: 32)
        .background(AppTheme.oat.opacity(0.15), in: Circle())

      Text(
        isFirstVisit
          ? "Each card is a pre-stocked fridge. Tap one to preview what\u{2019}s inside, then scan it \u{2014} everything here is safe to explore."
          : "Each card is a realistic fridge scenario with different ingredients. Tap one to see how FridgeLuck scans and identifies what\u{2019}s inside."
      )
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.oat.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.20), lineWidth: 1)
    )
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.05),
      value: appeared
    )
  }
}

struct DemoScenarioCard: View {
  let scenario: DemoScenario
  let index: Int
  let isOverlayVisible: Bool
  let appeared: Bool
  let reduceMotion: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Image(systemName: scenario.icon)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 44, height: 44)
          .background(Circle().fill(.white.opacity(0.15)))

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(scenario.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(scenario.description)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }

        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(scenario.ingredientNames.prefix(4), id: \.self) { name in
            Text(name)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.12), in: Capsule())
          }
          if scenario.ingredientNames.count > 4 {
            Text("+\(scenario.ingredientNames.count - 4)")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.6))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.08), in: Capsule())
          }
        }

        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "fork.knife")
            .font(.system(size: 10, weight: .medium))
          Text(scenario.recipeHint)
            .font(AppTheme.Typography.labelSmall)
        }
        .foregroundStyle(.white.opacity(0.58))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .background(
        LinearGradient(
          colors: scenario.gradientColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(.white.opacity(0.05))
          .frame(width: 60, height: 60)
          .blur(radius: 15)
          .offset(x: 15, y: -10)
          .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .shadow(color: scenario.accentColor.opacity(0.15), radius: 8, x: 0, y: 4)
      .rotationEffect(.degrees(scenario.cardRotation), anchor: .center)
    }
    .buttonStyle(.plain)
    .disabled(isOverlayVisible)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(
      reduceMotion
        ? nil : AppMotion.cardSpring.delay(Double(index) * AppMotion.staggerDelay + 0.08),
      value: appeared
    )
  }
}

struct DemoOwnPhotoCard: View {
  let isOverlayVisible: Bool
  let appeared: Bool
  let reduceMotion: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: AppTheme.Space.md) {
        Image(systemName: "camera.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .frame(width: 48, height: 48)
          .background(AppTheme.accentMuted, in: Circle())

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Use Your Own Photo")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Snap a photo of your real fridge or pantry.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(AppTheme.Space.md)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .strokeBorder(
            AppTheme.oat.opacity(0.40),
            style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(isOverlayVisible)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.28),
      value: appeared
    )
  }
}
