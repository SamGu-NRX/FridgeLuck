import SwiftUI

struct VirtualFridgeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var selectedLocation: InventoryStorageLocation?
  @State private var items: [InventoryActiveItem] = []
  @State private var isLoading = true
  @State private var appeared = false

  private var filteredItems: [InventoryActiveItem] {
    guard let selectedLocation else { return items }
    return items.filter { $0.storageLocation == selectedLocation }
  }

  private var locationCounts: [InventoryStorageLocation: Int] {
    Dictionary(grouping: items, by: \.storageLocation)
      .mapValues(\.count)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        headerSection
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        locationFilter
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        if isLoading {
          loadingState
            .padding(.horizontal, AppTheme.Space.page)
        } else if filteredItems.isEmpty {
          emptyState
            .padding(.horizontal, AppTheme.Space.page)
        } else {
          itemsList
            .padding(.horizontal, AppTheme.Space.page)
        }

        Spacer(minLength: AppTheme.Space.bottomClearance)
      }
      .padding(.top, AppTheme.Space.md)
    }
    .navigationTitle("My Kitchen")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .task {
      await loadItems()
    }
    .refreshable {
      await loadItems()
    }
    .onAppear {
      if !appeared {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.heroAppear.delay(0.1)) {
            appeared = true
          }
        }
      }
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Virtual Fridge")
            .font(AppTheme.Typography.displayLarge)
            .foregroundStyle(AppTheme.textPrimary)

          Text("\(items.count) items on hand")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .contentTransition(.numericText())
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)

        Spacer()

        summaryBadges
          .opacity(appeared ? 1 : 0)
          .offset(y: appeared ? 0 : 8)
      }
    }
  }

  @ViewBuilder
  private var summaryBadges: some View {
    let expiringSoon = items.filter(\.isExpiringSoon).count
    let lowStock = items.filter(\.isLowStock).count

    VStack(alignment: .trailing, spacing: AppTheme.Space.xxs) {
      if expiringSoon > 0 {
        FLStatusPill(text: "\(expiringSoon) expiring", kind: .warning)
      }
      if lowStock > 0 {
        FLStatusPill(text: "\(lowStock) low", kind: .warning)
      }
    }
  }

  // MARK: - Location Filter

  private var locationFilter: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: AppTheme.Space.xs) {
        locationChip(nil, label: "All", count: items.count)
        locationChip(.fridge, label: "Fridge", count: locationCounts[.fridge] ?? 0)
        locationChip(.pantry, label: "Pantry", count: locationCounts[.pantry] ?? 0)
        locationChip(.freezer, label: "Freezer", count: locationCounts[.freezer] ?? 0)
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 2),
      value: appeared
    )
  }

  private func locationChip(
    _ location: InventoryStorageLocation?,
    label: String,
    count: Int
  ) -> some View {
    let isSelected = selectedLocation == location
    return Button {
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        selectedLocation = location
      }
    } label: {
      HStack(spacing: AppTheme.Space.xxs) {
        Text(label)
          .font(AppTheme.Typography.label)
        if count > 0 {
          Text("\(count)")
            .font(AppTheme.Typography.labelSmall)
            .contentTransition(.numericText())
        }
      }
      .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(
        isSelected ? AppTheme.accent : AppTheme.surfaceMuted,
        in: Capsule()
      )
      .overlay(
        Capsule()
          .stroke(isSelected ? Color.clear : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isSelected)
  }

  // MARK: - Items List

  private var itemsList: some View {
    LazyVStack(spacing: AppTheme.Space.sm) {
      ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
        VirtualFridgeItemRow(item: item)
          .opacity(appeared ? 1 : 0)
          .offset(y: appeared ? 0 : 12)
          .animation(
            reduceMotion
              ? nil
              : AppMotion.cardSpring.delay(Double(min(index, 15)) * 0.025),
            value: appeared
          )
      }
    }
  }

  // MARK: - States

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)
      Text("Loading inventory...")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xxl)
  }

  private var emptyState: some View {
    FLEmptyState(
      title: selectedLocation == nil
        ? "Your kitchen is empty" : "Nothing in \(selectedLocation?.displayLabel ?? "")",
      message: selectedLocation == nil
        ? "Scan your fridge or add groceries to start tracking inventory."
        : "Items stored here will appear as you scan or add groceries.",
      systemImage: selectedLocation == nil ? "refrigerator" : "tray",
      actionTitle: "Update Groceries",
      action: {}
    )
  }

  // MARK: - Data

  private func loadItems() async {
    isLoading = true
    let inventoryRepository = deps.inventoryRepository
    do {
      let fetched = try await Task.detached(priority: .userInitiated) {
        try inventoryRepository.fetchAllActiveItems()
      }.value
      items = fetched
    } catch {
      items = []
    }
    isLoading = false
  }
}

// MARK: - InventoryStorageLocation Display

extension InventoryStorageLocation {
  var displayLabel: String {
    switch self {
    case .fridge: return "Fridge"
    case .pantry: return "Pantry"
    case .freezer: return "Freezer"
    case .unknown: return "Other"
    }
  }

  var icon: String {
    switch self {
    case .fridge: return "refrigerator"
    case .pantry: return "cabinet"
    case .freezer: return "snowflake"
    case .unknown: return "questionmark.folder"
    }
  }
}
