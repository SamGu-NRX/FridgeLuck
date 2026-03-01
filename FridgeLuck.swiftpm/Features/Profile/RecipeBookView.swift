import SwiftUI

/// Full recipe book / cooking journal. Shows all cooked meals with filter chips.
/// Presented as a sheet from DashboardView's "See All Recipes" button.
struct RecipeBookView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  @State private var entries: [CookingJournalEntry] = []
  @State private var isLoading = true
  @State private var selectedFilter: JournalFilter = .all
  @State private var selectedEntry: CookingJournalEntry?

  enum JournalFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    case thisWeek = "This Week"

    var id: String { rawValue }
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          loadingState
        } else if entries.isEmpty {
          emptyState
        } else {
          journalList
        }
      }
      .navigationTitle("Recipe Book")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .flPageBackground()
      .sheet(item: $selectedEntry) { entry in
        RecipeJournalDetailView(entry: entry)
          .environmentObject(deps)
      }
      .task {
        await loadEntries()
      }
    }
  }

  // MARK: - Filtered Entries

  private var filteredEntries: [CookingJournalEntry] {
    switch selectedFilter {
    case .all:
      return entries
    case .favorites:
      return entries.filter { ($0.rating ?? 0) >= 4 }
    case .thisWeek:
      let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
      return entries.filter { $0.cookedAt >= weekAgo }
    }
  }

  // MARK: - Loading

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      FLAnalyzingPulse()
        .frame(width: 44, height: 44)
      Text("Loading recipes...")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    FLEmptyState(
      title: "Your Recipe Book is Empty",
      message:
        "Every meal you cook will be saved here with its macros and your rating. Start cooking to build your collection!",
      systemImage: "book.closed"
    )
    .flPagePadding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Journal List

  private var journalList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        // Filter chips
        filterChips
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.xs)

        // Entry count
        Text("\(filteredEntries.count) meal\(filteredEntries.count == 1 ? "" : "s")")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        // Entries
        LazyVStack(spacing: AppTheme.Space.sm) {
          ForEach(filteredEntries) { entry in
            Button {
              selectedEntry = entry
            } label: {
              journalRow(entry: entry)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }
      .padding(.top, AppTheme.Space.md)
    }
  }

  // MARK: - Filter Chips

  private var filterChips: some View {
    HStack(spacing: AppTheme.Space.xs) {
      ForEach(JournalFilter.allCases) { filter in
        Button {
          withAnimation(AppMotion.quick) {
            selectedFilter = filter
          }
        } label: {
          Text(filterLabel(for: filter))
            .font(AppTheme.Typography.label)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .foregroundStyle(
              selectedFilter == filter ? .white : AppTheme.textSecondary
            )
            .background(
              selectedFilter == filter ? AppTheme.accent : AppTheme.surfaceMuted,
              in: Capsule()
            )
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
  }

  private func filterLabel(for filter: JournalFilter) -> String {
    switch filter {
    case .all:
      return "All"
    case .favorites:
      return "Favorites"
    case .thisWeek:
      return "This Week"
    }
  }

  // MARK: - Journal Row

  private func journalRow(entry: CookingJournalEntry) -> some View {
    FLCard {
      HStack(spacing: AppTheme.Space.sm) {
        // Thumbnail
        Group {
          if let imagePath = entry.imagePath,
            let image = deps.imageStorageService.load(relativePath: imagePath)
          {
            Image(uiImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            ZStack {
              AppTheme.surfaceMuted
              Image(systemName: "fork.knife")
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.oat)
            }
          }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

        // Info
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text(entry.recipe.title)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .fontWeight(.medium)
            .lineLimit(1)

          // Date
          Text(entry.cookedAt, format: .dateTime.month(.abbreviated).day().year())
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)

          // Rating stars
          if let rating = entry.rating, rating > 0 {
            HStack(spacing: 2) {
              ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                  .font(.system(size: 10))
                  .foregroundStyle(
                    star <= rating ? AppTheme.accent : AppTheme.oat.opacity(0.3)
                  )
              }
            }
          }
        }

        Spacer()

        // Calorie badge
        VStack(spacing: AppTheme.Space.xxxs) {
          Text("\(Int(entry.macrosConsumed.calories.rounded()))")
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("cal")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.oat)
      }
    }
  }

  // MARK: - Data Loading

  private func loadEntries() async {
    isLoading = true
    do {
      entries = try deps.userDataRepository.cookingJournal(limit: 200)
    } catch {
      entries = []
    }
    isLoading = false
  }
}
