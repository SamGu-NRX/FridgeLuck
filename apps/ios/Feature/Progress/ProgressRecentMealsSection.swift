import SwiftUI

struct ProgressRecentMealsSection: View {
  let recentJournal: [CookingJournalEntry]
  @EnvironmentObject var deps: AppDependencies

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      FLSectionHeader(
        "Recent Meals",
        subtitle: "\(recentJournal.count) logged",
        icon: "clock.arrow.circlepath"
      )
      .padding(.horizontal, AppTheme.Space.page)

      if recentJournal.isEmpty {
        emptyState
          .padding(.horizontal, AppTheme.Space.page)
      } else {
        mealScroll
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .onAppear {
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 5)) {
          appeared = true
        }
      }
    }
  }

  // MARK: - Meal Scroll

  private var mealScroll: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: AppTheme.Space.sm) {
        ForEach(Array(recentJournal.prefix(8).enumerated()), id: \.element.id) { index, entry in
          mealCard(entry: entry, index: index)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
  }

  private func mealCard(entry: CookingJournalEntry, index: Int) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Group {
        if let imagePath = entry.imagePath,
          let image = deps.imageStorageService.load(relativePath: imagePath)
        {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          ZStack {
            AppTheme.heroLight.opacity(0.3)
            Image(systemName: "fork.knife")
              .font(.system(size: 22))
              .foregroundStyle(AppTheme.oat)
          }
        }
      }
      .frame(width: 140, height: 100)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

      Text(entry.recipe.title)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textPrimary)
        .fontWeight(.medium)
        .lineLimit(2)

      Text(entry.cookedAt, format: .dateTime.month(.abbreviated).day())
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)

      if let rating = entry.rating, rating > 0 {
        HStack(spacing: 2) {
          ForEach(1...5, id: \.self) { star in
            Image(systemName: star <= rating ? "star.fill" : "star")
              .font(.system(size: 10))
              .foregroundStyle(star <= rating ? AppTheme.accent : AppTheme.oat.opacity(0.3))
          }
        }
      }

      Text("\(Int(entry.macrosConsumed.calories.rounded())) cal")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(width: 140)
    .padding(AppTheme.Space.sm)
    .background(
      AppTheme.surfaceElevated,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
    )
    .accessibilityLabel(
      "\(entry.recipe.title), cooked on \(entry.cookedAt.formatted(.dateTime.month(.abbreviated).day())), \(Int(entry.macrosConsumed.calories.rounded())) calories\(entry.rating.map { ", rated \($0) stars" } ?? "")"
    )
  }

  // MARK: - Empty State

  private var emptyState: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "fork.knife")
        .font(.system(size: 18))
        .foregroundStyle(AppTheme.oat)
        .frame(width: 44, height: 44)
        .background(AppTheme.surfaceMuted, in: Circle())

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text("No meals logged yet")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Cook a recipe and it will appear here.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
    .padding(AppTheme.Space.md)
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
