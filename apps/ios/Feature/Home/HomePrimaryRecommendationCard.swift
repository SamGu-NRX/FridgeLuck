import SwiftUI

struct HomePrimaryRecommendationCard: View {
  let recipeName: String
  let explanation: String
  let cookTimeMinutes: Int?
  let matchLabel: String?
  let onCook: () -> Void
  let onScan: () -> Void
  let hasRecommendation: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    if hasRecommendation {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        ZStack(alignment: .bottomLeading) {
          LinearGradient(
            colors: [AppTheme.heroLight, AppTheme.heroMid],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          .frame(height: AppTheme.Space.cardImageHeight)
          .overlay(alignment: .center) {
            Image(systemName: "fork.knife")
              .font(.system(size: 32, weight: .medium))
              .foregroundStyle(.white.opacity(0.25))
          }
          .overlay(alignment: .bottom) {
            LinearGradient(
              colors: [AppTheme.surface.opacity(0), AppTheme.surface],
              startPoint: .top,
              endPoint: .bottom
            )
            .frame(height: 80)
          }
        }
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: AppTheme.Radius.xl,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: AppTheme.Radius.xl
          )
        )

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text(recipeName)
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(AppTheme.textPrimary)

          Text(explanation)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(3)

          HStack(spacing: AppTheme.Space.xs) {
            if let time = cookTimeMinutes {
              pillView(text: "\(time) min", icon: "clock")
            }
            if let label = matchLabel {
              pillView(text: label, icon: "checkmark.seal.fill")
            }
          }
          .padding(.top, AppTheme.Space.xxs)

          FLPrimaryButton("Let's Cook", systemImage: "flame.fill") {
            onCook()
          }
          .padding(.top, AppTheme.Space.xs)
        }
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.md)
      }
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.colorDeep, radius: 20, x: 0, y: 10)
      .scaleEffect(appeared ? 1 : 0.98)
      .opacity(appeared ? 1 : 0)
      .onAppear {
        guard !appeared else { return }
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.heroAppear.delay(AppMotion.staggerInterval * 3)) {
            appeared = true
          }
        }
      }
    } else {
      VStack(spacing: AppTheme.Space.lg) {
        Image(systemName: "sparkles")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(AppTheme.accent)

        VStack(spacing: AppTheme.Space.xs) {
          Text("What should you cook?")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Scan your fridge to get personalized recipe recommendations.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        FLPrimaryButton("Scan Fridge", systemImage: "camera.fill") {
          onScan()
        }
      }
      .padding(AppTheme.Space.lg)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
  }

  private func pillView(text: String, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
      Text(text)
        .font(AppTheme.Typography.labelSmall)
    }
    .foregroundStyle(AppTheme.accent)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(AppTheme.accentMuted, in: Capsule())
  }
}
