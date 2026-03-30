import SwiftUI

struct HomeActiveStateCard: View {
  let recipeName: String
  let stepDescription: String
  let onResume: () -> Void

  var body: some View {
    Button(action: onResume) {
      HStack(spacing: AppTheme.Space.md) {
        ZStack {
          Circle()
            .fill(AppTheme.accent.opacity(0.15))
            .frame(width: 48, height: 48)
          Image(systemName: "flame.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Continue cooking")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .textCase(.uppercase)
            .kerning(0.8)
          Text(recipeName)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(stepDescription)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(.white.opacity(0.65))
        }

        Spacer()

        Image(systemName: "arrow.right")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .padding(AppTheme.Space.sm)
          .background(AppTheme.accent.opacity(0.15), in: Circle())
          .accessibilityHidden(true)
      }
      .padding(AppTheme.Space.md)
      .background(
        AppTheme.deepOlive,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.slabStroke, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint("Resume the current cooking session.")
  }
}
