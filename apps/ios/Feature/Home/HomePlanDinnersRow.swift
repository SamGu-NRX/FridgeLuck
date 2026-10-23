import SwiftUI

/// Home's entry to the plan sheet, under Tonight's pick: the spec's "decide the next few days"
/// intent sits where the user is already deciding what to eat (SPEC.md §3.2 entry points).
struct HomePlanDinnersRow: View {
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "calendar")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(AppTheme.accent)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Plan the next few dinners")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textPrimary)
          Text("From your kitchen, with a shopping list")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .multilineTextAlignment(.leading)

        Spacer(minLength: AppTheme.Space.xs)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
          .accessibilityHidden(true)
      }
      .padding(AppTheme.Space.md)
      .frame(minHeight: 44)
      .background(
        AppTheme.surfaceElevated,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(FLPressableButtonStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Plan the next few dinners")
    .accessibilityHint("Plans dinners from what's in your kitchen, with a shopping list.")
    .accessibilityIdentifier("home_plan_dinners")
  }
}
