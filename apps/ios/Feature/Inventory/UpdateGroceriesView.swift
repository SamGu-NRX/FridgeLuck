import SwiftUI
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "UpdateGroceriesView")

struct UpdateGroceriesView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  private enum GroceryStage: Int {
    case selectMode = 1
    case capture = 2
    case analyze = 3
    case review = 4

    var name: String {
      switch self {
      case .selectMode: return "Mode"
      case .capture: return "Capture"
      case .analyze: return "Analyzing"
      case .review: return "Review"
      }
    }

    var progress: Double {
      Double(rawValue) / 4.0
    }
  }

  // MARK: - State

  let launchMode: UpdateGroceriesLaunchMode

  @State private var selectedMode: UpdateGroceriesLaunchMode?
  @State private var stage: GroceryStage = .selectMode
  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var pendingItems: [GroceryPendingItem] = []
  @State private var isCommitting = false
  @State private var showSuccess = false
  @State private var stageAppeared = false
  @State private var showIngredientPicker = false
  @State private var selectedIngredientIDs: Set<Int64> = []
  @State private var hasAppliedLaunchMode = false
  @State private var cameraLaunchTask: Task<Void, Never>?
  @State private var successDismissTask: Task<Void, Never>?
  @State private var stageAppearanceTask: Task<Void, Never>?

  init(launchMode: UpdateGroceriesLaunchMode = .chooser) {
    self.launchMode = launchMode
  }

  private var captureImagesBinding: Binding<[UIImage]> {
    Binding(
      get: { capturedImage.map { [$0] } ?? [] },
      set: { images in
        capturedImage = images.last
      }
    )
  }

  private var captureConfiguration: FLCaptureConfiguration {
    let mode = selectedMode ?? launchMode
    return FLCaptureConfiguration(
      title: mode.captureTitle,
      subtitle: mode.captureSubtitle,
      maxPhotos: 1
    )
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      ScanArcStageIndicator(
        stageProgress: stage.progress,
        stageName: stage.name,
        stageIndex: stage.rawValue,
        totalSteps: 4,
        reduceMotion: reduceMotion
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.lg)

      ZStack {
        Group {
          switch stage {
          case .selectMode:
            modeSelectionView
          case .capture:
            captureTransitionView
          case .analyze:
            analyzeView
          case .review:
            GroceryReviewSection(
              items: $pendingItems,
              isCommitting: isCommitting,
              onCommit: commitGroceries,
              onAddMore: {
                showIngredientPicker = true
              }
            )
          }
        }
        .transition(
          reduceMotion
            ? .opacity
            : .asymmetric(
              insertion: .move(edge: .trailing).combined(with: .opacity),
              removal: .move(edge: .leading).combined(with: .opacity)
            )
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .clipped()
    }
    .navigationTitle("Update Groceries")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .overlay {
      if showSuccess {
        successOverlay
      }
    }
    .fullScreenCover(isPresented: $showCamera) {
      FLCaptureView(
        configuration: captureConfiguration,
        capturedImages: captureImagesBinding,
        onDone: {
          if capturedImage != nil {
            advanceToAnalyze()
          }
        }
      )
    }
    .sheet(isPresented: $showIngredientPicker, onDismiss: onIngredientPickerDismiss) {
      IngredientPickerView(
        title: "Add Ingredients",
        selectedIDs: $selectedIngredientIDs
      )
    }
    .task {
      applyLaunchModeIfNeeded()
    }
    .onDisappear {
      cancelPendingTasks()
    }
    .onChange(of: showCamera) { _, isShowing in
      if !isShowing, capturedImage == nil, stage == .capture {
        if launchMode.isDirectEntry {
          dismiss()
        } else {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            stage = .selectMode
            stageAppeared = false
          }
          triggerStageAppearance()
        }
      }
    }
  }

  // MARK: - Mode Selection

  private var modeSelectionView: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        Spacer(minLength: AppTheme.Space.md)

        VStack(spacing: AppTheme.Space.xs) {
          Text("How would you like to add?")
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)

          Text("Choose an entry method for your groceries.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.md) {
          ForEach(Array(UpdateGroceriesLaunchMode.entryModes.enumerated()), id: \.element) {
            index, mode in
            modeCard(mode, staggerIndex: index)
          }
        }

        Spacer(minLength: AppTheme.Space.xl)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .onAppear { triggerStageAppearance() }
  }

  private func modeCard(_ mode: UpdateGroceriesLaunchMode, staggerIndex: Int) -> some View {
    Button {
      selectedMode = mode
      advanceToCaptureOrReview(mode: mode)
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        ZStack {
          Circle()
            .fill(mode.iconColor.opacity(0.12))
            .frame(width: 48, height: 48)

          Image(systemName: mode.icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(mode.iconColor)
        }

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(mode.title)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .fontWeight(.medium)

          Text(mode.subtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.oat.opacity(0.5))
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
      .shadow(color: AppTheme.Shadow.color, radius: 6, x: 0, y: 2)
    }
    .buttonStyle(FLPressableButtonStyle())
    .opacity(stageAppeared ? 1 : 0)
    .offset(y: stageAppeared ? 0 : 12)
    .animation(
      reduceMotion
        ? nil
        : AppMotion.cardSpring.delay(Double(staggerIndex) * AppMotion.staggerDelay),
      value: stageAppeared
    )
  }

  // MARK: - Capture Transition View

  private var captureTransitionView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer()
      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)
      Text("Opening camera\u{2026}")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .onAppear {
      scheduleCameraLaunch()
    }
  }

  // MARK: - Analyze View

  private var analyzeView: some View {
    ScanAnalyzingView(
      capturedImage: capturedImage,
      fallbackStateText: nil,
      reduceMotion: reduceMotion,
      title: "Identifying groceries",
      subtitle: "Matching items and estimating quantities."
    )
    .padding(.horizontal, AppTheme.Space.page)
    .task {
      try? await Task.sleep(for: reduceMotion ? .milliseconds(500) : .milliseconds(1300))
      guard !Task.isCancelled else { return }

      let demoItems = generateDemoGroceryItems()
      pendingItems = demoItems

      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        stage = .review
        stageAppeared = false
      }
      triggerStageAppearance()
    }
  }

  // MARK: - Success Overlay

  private var successOverlay: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.96)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        ZStack {
          Circle()
            .fill(
              RadialGradient(
                colors: [AppTheme.sage.opacity(0.20), AppTheme.sage.opacity(0.04)],
                center: .center,
                startRadius: 16,
                endRadius: 72
              )
            )
            .frame(width: 120, height: 120)

          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(AppTheme.sage)
        }

        VStack(spacing: AppTheme.Space.xs) {
          Text("Items added!")
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)

          Text("Your virtual fridge has been updated.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
    .onAppear {
      scheduleSuccessDismiss()
    }
  }

  // MARK: - Navigation Helpers

  private func applyLaunchModeIfNeeded() {
    guard launchMode.isDirectEntry, !hasAppliedLaunchMode else { return }
    hasAppliedLaunchMode = true
    selectedMode = launchMode
    advanceToCaptureOrReview(mode: launchMode)
  }

  private func cancelPendingTasks() {
    cameraLaunchTask?.cancel()
    cameraLaunchTask = nil
    successDismissTask?.cancel()
    successDismissTask = nil
    stageAppearanceTask?.cancel()
    stageAppearanceTask = nil
  }

  private func scheduleCameraLaunch() {
    cameraLaunchTask?.cancel()

    guard !reduceMotion else {
      showCamera = true
      return
    }

    cameraLaunchTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }

      showCamera = true
      cameraLaunchTask = nil
    }
  }

  private func scheduleSuccessDismiss() {
    successDismissTask?.cancel()
    successDismissTask = Task { @MainActor in
      try? await Task.sleep(for: reduceMotion ? .milliseconds(800) : .milliseconds(1600))
      guard !Task.isCancelled else { return }

      dismiss()
      successDismissTask = nil
    }
  }

  private func advanceToCaptureOrReview(mode: UpdateGroceriesLaunchMode) {
    switch mode {
    case .photo, .receipt:
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        stage = .capture
        stageAppeared = false
      }
    case .manual:
      selectedIngredientIDs = []
      showIngredientPicker = true
    case .chooser:
      break
    }
  }

  private func onIngredientPickerDismiss() {
    guard !selectedIngredientIDs.isEmpty else {
      if launchMode.isDirectEntry, pendingItems.isEmpty {
        dismiss()
      }
      return
    }

    let ingredients = (try? deps.ingredientRepository.fetch(ids: selectedIngredientIDs)) ?? []
    let newItems = ingredients.compactMap { ingredient -> GroceryPendingItem? in
      guard let id = ingredient.id else { return nil }
      return GroceryPendingItem(
        ingredientId: id,
        ingredientName: ingredient.displayName,
        quantityGrams: InventoryIntakeService.estimateGrams(forName: ingredient.displayName),
        storageLocation: InventoryIntakeService.inferLocation(forName: ingredient.displayName),
        confidenceScore: 1.0,
        source: .manual,
        isConfirmed: true
      )
    }

    let existingIDs = Set(pendingItems.map(\.ingredientId))
    let uniqueNew = newItems.filter { !existingIDs.contains($0.ingredientId) }
    pendingItems.append(contentsOf: uniqueNew)

    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
      stage = .review
      stageAppeared = false
    }
    triggerStageAppearance()
  }

  private func advanceToAnalyze() {
    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
      stage = .analyze
      stageAppeared = false
    }
  }

  private func triggerStageAppearance() {
    if reduceMotion {
      stageAppearanceTask?.cancel()
      stageAppearanceTask = nil
      stageAppeared = true
    } else {
      stageAppearanceTask?.cancel()
      stageAppearanceTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }

        withAnimation(AppMotion.cardSpring) {
          stageAppeared = true
        }
        stageAppearanceTask = nil
      }
    }
  }

  // MARK: - Commit

  private func commitGroceries() {
    let confirmed = pendingItems.filter(\.isConfirmed)
    guard !confirmed.isEmpty else { return }

    isCommitting = true

    Task {
      let groceryItems = confirmed.map { item in
        InventoryIntakeService.GroceryIngestItem(
          ingredientId: item.ingredientId,
          quantityGrams: item.quantityGrams,
          storageLocation: item.storageLocation,
          confidenceScore: item.confidenceScore,
          source: item.source
        )
      }

      do {
        _ = try deps.inventoryIntakeService.ingestGroceryItems(
          items: groceryItems,
          sourceRef: "grocery_update_\(UUID().uuidString)"
        )

        withAnimation(reduceMotion ? nil : AppMotion.celebration) {
          showSuccess = true
        }
      } catch {
        logger.error("Failed to commit groceries: \(error.localizedDescription)")
        isCommitting = false
      }
    }
  }

  // MARK: - Demo Grocery Items

  private func generateDemoGroceryItems() -> [GroceryPendingItem] {
    let demoItems: [(id: Int64, confidence: Double)] = [
      (3, 0.93),
      (1, 0.96),
      (15, 0.88),
      (8, 0.82),
      (9, 0.85),
      (10, 0.79),
      (7, 0.91),
      (6, 0.94),
    ]

    return demoItems.map { item in
      GroceryPendingItem(
        ingredientId: item.id,
        ingredientName: IngredientLexicon.displayName(for: item.id),
        quantityGrams: InventoryIntakeService.estimateGrams(
          forName: IngredientLexicon.displayName(for: item.id)
        ),
        storageLocation: InventoryIntakeService.inferLocation(
          forName: IngredientLexicon.displayName(for: item.id)
        ),
        confidenceScore: item.confidence,
        source: .scan,
        isConfirmed: item.confidence >= 0.80
      )
    }
  }
}
