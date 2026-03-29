import SwiftUI

struct ProgressSavedWinnersSection: View {
  let winners: [SavedWinner]
  @EnvironmentObject var deps: AppDependencies

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    if !winners.isEmpty {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        HStack(alignment: .center) {
          FLSectionHeader("Winners", icon: "star.fill")

          Spacer()

          if winners.count > 4 {
            NavigationLink {
              SavedWinnersView(winners: winners)
                .environmentObject(deps)
            } label: {
              Text("See All")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: AppTheme.Space.sm),
            GridItem(.flexible(), spacing: AppTheme.Space.sm),
          ],
          spacing: AppTheme.Space.sm
        ) {
          ForEach(Array(winners.prefix(4).enumerated()), id: \.element.id) { index, winner in
            winnerCard(winner: winner, index: index)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
      }
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 10)
      .onAppear {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 6)) {
            appeared = true
          }
        }
      }
    }
  }

  // MARK: - Winner Card

  private func winnerCard(winner: SavedWinner, index: Int) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      ZStack(alignment: .topLeading) {
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
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.6))
            }
          }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

        if winner.cookCount > 1 {
          Text("\(winner.cookCount)x")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.xxxs)
            .background(AppTheme.accent.opacity(0.85), in: Capsule())
            .padding(AppTheme.Space.xs)
        }
      }

      Text(winner.recipeName)
        .font(AppTheme.Typography.bodySmall)
        .fontWeight(.medium)
        .foregroundStyle(AppTheme.textPrimary)
        .lineLimit(2)

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
    }
    .padding(AppTheme.Space.sm)
    .background(
      AppTheme.surfaceElevated,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
    )
  }
}

// MARK: - Display Model

struct SavedWinner: Identifiable, Sendable {
  let id: String
  let recipeName: String
  let rating: Int
  let cookCount: Int
  let imagePath: String?
  let lastCookedAt: Date
}
