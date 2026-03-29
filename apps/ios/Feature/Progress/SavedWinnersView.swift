import SwiftUI

struct SavedWinnersView: View {
  let winners: [SavedWinner]
  @EnvironmentObject var deps: AppDependencies

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var headerAppeared = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text("Your Winners")
            .font(AppTheme.Typography.displayLarge)
            .foregroundStyle(AppTheme.textPrimary)

          Text("\(winners.count) recipe\(winners.count == 1 ? "" : "s") you love")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.sectionBreak)
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : -8)

        if winners.isEmpty {
          emptyState
            .padding(.horizontal, AppTheme.Space.page)
        } else {
          LazyVStack(spacing: AppTheme.Space.sm) {
            ForEach(winners) { winner in
              winnerRow(winner: winner)
            }
          }
          .padding(.horizontal, AppTheme.Space.page)
        }
      }
      .padding(.bottom, AppTheme.Space.bottomClearance)
    }
    .flPageBackground()
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      if reduceMotion {
        headerAppeared = true
      } else {
        withAnimation(AppMotion.tabEntrance) {
          headerAppeared = true
        }
      }
    }
  }

  // MARK: - Winner Row

  private func winnerRow(winner: SavedWinner) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      Group {
        if let imagePath = winner.imagePath,
          let image = deps.imageStorageService.load(relativePath: imagePath)
        {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          ZStack {
            LinearGradient(
              colors: [AppTheme.heroLight, AppTheme.heroMid],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
            Image(systemName: "fork.knife")
              .font(.system(size: 16))
              .foregroundStyle(.white.opacity(0.6))
          }
        }
      }
      .frame(width: 68, height: 68)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(winner.recipeName)
          .font(AppTheme.Typography.bodyMedium)
          .fontWeight(.medium)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(2)

        HStack(spacing: AppTheme.Space.sm) {
          if winner.rating > 0 {
            HStack(spacing: 2) {
              ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= winner.rating ? "star.fill" : "star")
                  .font(.system(size: 9))
                  .foregroundStyle(
                    star <= winner.rating ? AppTheme.accent : AppTheme.oat.opacity(0.3))
              }
            }
          }

          if winner.cookCount > 1 {
            Text("Cooked \(winner.cookCount)x")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        Text(winner.lastCookedAt, format: .dateTime.month(.abbreviated).day())
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
  }

  // MARK: - Empty State

  private var emptyState: some View {
    FLEmptyState(
      title: "No winners yet",
      message: "Rate recipes 4+ stars or cook one 3+ times and it will appear here.",
      systemImage: "star.fill",
      actionTitle: nil,
      action: nil
    )
  }
}
