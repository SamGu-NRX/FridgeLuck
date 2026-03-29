import SwiftUI

struct HomeFallbackOption: Identifiable {
  let id: String
  let recipeName: String
  let cookTimeMinutes: Int?
  let badgeLabel: String
  let badgeColor: Color
}

struct HomeFallbackOptionsRow: View {
  let options: [HomeFallbackOption]
  let onSelect: (HomeFallbackOption) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLSectionHeader("More Ideas", icon: "lightbulb.fill")
        .padding(.horizontal, AppTheme.Space.page)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: AppTheme.Space.sm) {
          ForEach(options) { option in
            fallbackCard(option)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
      }
    }
  }

  private func fallbackCard(_ option: HomeFallbackOption) -> some View {
    Button {
      onSelect(option)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        ZStack {
          AppTheme.surfaceMuted
          Image(systemName: "fork.knife")
            .font(.system(size: 18))
            .foregroundStyle(AppTheme.oat)
        }
        .frame(width: 156, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
        .overlay(alignment: .topLeading) {
          Text(option.badgeLabel)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.xxxs + 1)
            .background(option.badgeColor.opacity(0.85), in: Capsule())
            .padding(AppTheme.Space.xs)
        }

        Text(option.recipeName)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(2)
          .frame(width: 156, alignment: .leading)

        if let time = option.cookTimeMinutes {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "clock")
              .font(.system(size: 9, weight: .medium))
            Text("\(time) min")
              .font(AppTheme.Typography.labelSmall)
          }
          .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .frame(width: 156)
      .padding(AppTheme.Space.xs)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
    .buttonStyle(FLPressableButtonStyle())
  }
}
