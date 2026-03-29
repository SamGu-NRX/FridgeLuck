import SwiftUI

struct HomeUseSoonAlert: View {
  let ingredientName: String
  let daysRemaining: Int
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "clock.badge.exclamationmark")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(AppTheme.accent)

        Text(ingredientName)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)

        Spacer()

        Text(daysRemaining == 1 ? "1 day left" : "\(daysRemaining) days left")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.accent)
          .padding(.horizontal, AppTheme.Space.sm)
          .padding(.vertical, AppTheme.Space.chipVertical)
          .background(AppTheme.accentMuted, in: Capsule())

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        AppTheme.accent.opacity(0.07),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(AppTheme.accent.opacity(0.15), lineWidth: 1)
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .accessibilityLabel(
      "\(ingredientName), \(daysRemaining) days until expiry. Tap to view in Kitchen.")
  }
}
