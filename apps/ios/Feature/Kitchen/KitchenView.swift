import SwiftUI

struct KitchenView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let deps: AppDependencies
  private let onOpenGroceriesFlow: (UpdateGroceriesLaunchMode) -> Void

  @State private var viewModel: KitchenViewModel
  @State private var selectedLocation: InventoryStorageLocation? = nil
  @State private var headerAppeared = false
  @State private var sectionsAppeared = false
  @State private var showStaplePicker = false
  @State private var selectedStapleIDs: Set<Int64> = []

  private let locationOrder: [InventoryStorageLocation] = [.fridge, .pantry, .freezer]

  init(
    deps: AppDependencies,
    onOpenGroceriesFlow: @escaping (UpdateGroceriesLaunchMode) -> Void = { _ in }
  ) {
    self.deps = deps
    self.onOpenGroceriesFlow = onOpenGroceriesFlow
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

        if !viewModel.hasLoaded || (viewModel.isLoading && !hasKitchenContent) {
          loadingState
        } else if let errorMessage = viewModel.errorMessage, !hasKitchenContent {
          errorState(message: errorMessage)
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sectionBreak)
        } else if !hasKitchenContent {
          emptyState
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sectionBreak)
        } else {
          if let errorMessage = viewModel.errorMessage {
            refreshErrorBanner(message: errorMessage)
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.top, AppTheme.Space.lg)
          }

          if !viewModel.allItems.isEmpty {
            locationFilter
              .padding(.top, AppTheme.Space.lg)
          }

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
                onOpenGroceriesFlow(.photo)
              },
              onScanReceipt: {
                onOpenGroceriesFlow(.receipt)
              },
              onAddManual: {
                onOpenGroceriesFlow(.manual)
              }
            )
            .opacity(sectionsAppeared ? 1 : 0)
            .offset(y: sectionsAppeared ? 0 : 12)

            PantryAssumptionsSection(
              assumptions: viewModel.pantryAssumptions,
              onCycleTier: { id in Task { await viewModel.cyclePantryTier(ingredientId: id) } },
              onRemove: { id in Task { await viewModel.removePantryAssumption(ingredientId: id) } },
              onAddStaple: {
                selectedStapleIDs = []
                showStaplePicker = true
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
    .sheet(isPresented: $showStaplePicker, onDismiss: handleStaplePickerDismiss) {
      IngredientPickerView(
        title: "Pantry Staples",
        selectedIDs: $selectedStapleIDs
      )
      .environmentObject(deps)
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

  private var hasKitchenContent: Bool {
    !viewModel.allItems.isEmpty || !viewModel.pantryAssumptions.isEmpty
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

  private func errorState(message: String) -> some View {
    FLEmptyState(
      title: "Kitchen unavailable",
      message: message,
      systemImage: "exclamationmark.triangle.fill",
      actionTitle: "Try Again"
    ) {
      Task { await viewModel.load() }
    }
  }

  private func refreshErrorBanner(message: String) -> some View {
    FLCard(tone: .warm) {
      HStack(alignment: .top, spacing: AppTheme.Space.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppTheme.dustyRose)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Kitchen refresh failed")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textPrimary)
          Text(message)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer(minLength: AppTheme.Space.sm)

        Button("Retry") {
          Task { await viewModel.load() }
        }
        .font(AppTheme.Typography.label)
      }
    }
  }

  private var emptyState: some View {
    FLEmptyState(
      title: "Your kitchen is empty",
      message: "Add groceries to start building a live view of what you have on hand.",
      systemImage: "refrigerator",
      actionTitle: "Add Groceries"
    ) {
      onOpenGroceriesFlow(.chooser)
    }
  }

  private func handleStaplePickerDismiss() {
    let pickedIDs = selectedStapleIDs
    selectedStapleIDs = []

    guard !pickedIDs.isEmpty else { return }
    Task {
      await viewModel.addPantryAssumptions(ingredientIDs: pickedIDs)
    }
  }
}
