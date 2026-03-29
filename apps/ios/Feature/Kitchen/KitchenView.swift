import SwiftUI

struct KitchenView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var viewModel: KitchenViewModel
  @State private var selectedLocation: InventoryStorageLocation? = nil
  @State private var headerAppeared = false
  @State private var sectionsAppeared = false

  private let locationOrder: [InventoryStorageLocation] = [.fridge, .pantry, .freezer]

  init(deps: AppDependencies) {
    _viewModel = State(wrappedValue: KitchenViewModel(deps: deps))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.md)
          .opacity(headerAppeared ? 1 : 0)
          .offset(y: headerAppeared ? 0 : -8)

        if !viewModel.hasLoaded || viewModel.isLoading {
          loadingState
        } else if viewModel.allItems.isEmpty {
          emptyState
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sectionBreak)
        } else {
          locationFilter
            .padding(.top, AppTheme.Space.lg)

          VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
            KitchenUseSoonSection(items: viewModel.useSoonItems)
              .opacity(sectionsAppeared ? 1 : 0)
              .offset(y: sectionsAppeared ? 0 : 12)

            KitchenNeedsReviewSection(items: viewModel.needsReviewItems)
              .opacity(sectionsAppeared ? 1 : 0)
              .offset(y: sectionsAppeared ? 0 : 12)

            KitchenOnHandSection(
              groupedItems: viewModel.groupedByLocation,
              locationOrder: effectiveLocationOrder
            )
            .opacity(sectionsAppeared ? 1 : 0)
            .offset(y: sectionsAppeared ? 0 : 12)

            KitchenQuickAddSection(
              onScanGroceries: {
                // TODO: Connect this action to the grocery scan capture flow.
              },
              onAddManual: {
                // TODO: Connect this action to the manual grocery entry flow.
              }
            )
            .opacity(sectionsAppeared ? 1 : 0)
            .offset(y: sectionsAppeared ? 0 : 12)

            PantryAssumptionsSection(
              assumptions: viewModel.pantryAssumptions,
              onCycleTier: { id in Task { await viewModel.cyclePantryTier(ingredientId: id) } },
              onRemove: { id in Task { await viewModel.removePantryAssumption(ingredientId: id) } },
              onAddStaple: {
                // TODO: Present the pantry staple picker once Kitchen can launch ingredient search.
              }
            )
            .opacity(sectionsAppeared ? 1 : 0)
            .offset(y: sectionsAppeared ? 0 : 12)
          }
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.sectionBreak)
          .onAppear {
            guard !sectionsAppeared else { return }
            if reduceMotion {
              sectionsAppeared = true
            } else {
              withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 2)) {
                sectionsAppeared = true
              }
            }
          }
        }
      }
      .padding(
        .bottom,
        AppTheme.Space.bottomClearance + AppTheme.Home.navOrbLift + AppTheme.Home.navBaseOffset)
    }
    .flPageBackground()
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await viewModel.load()
    }
    .refreshable {
      await viewModel.load()
    }
    .onAppear {
      guard !headerAppeared else { return }
      if reduceMotion {
        headerAppeared = true
      } else {
        withAnimation(AppMotion.tabEntrance) {
          headerAppeared = true
        }
      }
    }
  }

  private var effectiveLocationOrder: [InventoryStorageLocation] {
    let hasUnknown = viewModel.filteredItems.contains { $0.storageLocation == .unknown }
    return hasUnknown ? locationOrder + [.unknown] : locationOrder
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text("Kitchen")
          .font(AppTheme.Typography.displayLarge)
          .foregroundStyle(AppTheme.textPrimary)

        if viewModel.itemCount > 0 {
          Text("\(viewModel.itemCount) items on hand")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .contentTransition(.numericText())
        } else {
          Text("What you have on hand")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }

      Spacer()

      if viewModel.expiringCount > 0 {
        FLStatusPill(text: "\(viewModel.expiringCount) expiring", kind: .warning)
      }
    }
  }

  // MARK: - Location Filter

  private var locationFilter: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: AppTheme.Space.xs) {
        locationChip(
          title: "All",
          count: viewModel.allItems.count,
          isActive: selectedLocation == nil
        ) {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            selectedLocation = nil
            viewModel.selectedLocation = nil
          }
        }
        ForEach(locationOrder, id: \.self) { location in
          let count = viewModel.locationCounts[location, default: 0]
          if count > 0 {
            locationChip(
              title: location.displayLabel,
              count: count,
              isActive: selectedLocation == location
            ) {
              withAnimation(reduceMotion ? nil : AppMotion.gentle) {
                selectedLocation = location
                viewModel.selectedLocation = location
              }
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
  }

  private func locationChip(
    title: String,
    count: Int,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: AppTheme.Space.xxs) {
        Text(title)
          .font(AppTheme.Typography.label)
        if count > 0 {
          Text("\(count)")
            .font(AppTheme.Typography.labelSmall)
            .contentTransition(.numericText())
        }
      }
      .foregroundStyle(isActive ? .white : AppTheme.textPrimary)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(
        isActive ? AppTheme.accent : AppTheme.surfaceMuted,
        in: Capsule()
      )
      .overlay(
        Capsule()
          .stroke(isActive ? Color.clear : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isActive)
  }

  // MARK: - States

  private var loadingState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)
      Text("Loading kitchen...")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xxl)
  }

  private var emptyState: some View {
    FLEmptyState(
      title: "Your kitchen is empty",
      message: "Scan your fridge or add groceries to see what you have on hand.",
      systemImage: "refrigerator",
      actionTitle: "Scan Fridge"
    ) {
      // TODO: Reuse the grocery scan capture flow for the empty kitchen CTA.
    }
  }
}
