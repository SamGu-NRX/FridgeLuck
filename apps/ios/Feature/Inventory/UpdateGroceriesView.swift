import PhotosUI
import SwiftUI
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "UpdateGroceriesView")

struct UpdateGroceriesView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  // MARK: - Enums

  private enum GroceryEntryMode: String, CaseIterable {
    case photo
    case receipt
    case manual

    var title: String {
      switch self {
      case .photo: return "Photograph groceries"
      case .receipt: return "Scan a receipt"
      case .manual: return "Add items manually"
      }
    }

    var subtitle: String {
      switch self {
      case .photo: return "Snap a photo of your haul"
      case .receipt: return "OCR your shopping receipt"
      case .manual: return "Search and add by hand"
      }
    }

    var icon: String {
      switch self {
      case .photo: return "camera.fill"
      case .receipt: return "doc.text.viewfinder"
      case .manual: return "text.badge.plus"
      }
    }

    var iconColor: Color {
      switch self {
      case .photo: return AppTheme.accent
      case .receipt: return AppTheme.sage
      case .manual: return AppTheme.oat
      }
    }
  }

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

  @State private var selectedMode: GroceryEntryMode?
  @State private var stage: GroceryStage = .selectMode
  @State private var capturedImage: UIImage?
  @State private var capturedImages: [UIImage] = []
  @State private var showCamera = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var pendingItems: [GroceryPendingItem] = []
  @State private var isCommitting = false
  @State private var showSuccess = false
  @State private var stageAppeared = false
  @State private var showIngredientPicker = false
  @State private var selectedIngredientIDs: Set<Int64> = []

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
        configuration: FLCaptureConfiguration(
          title: selectedMode == .receipt ? "Scan Receipt" : "Photograph Groceries",
          subtitle: selectedMode == .receipt
            ? "Center the receipt in frame"
            : "Lay out items for best results",
          maxPhotos: 1
        ),
        capturedImages: $capturedImages,
        onDone: {
          if let lastImage = capturedImages.last {
            capturedImage = lastImage
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
    .onChange(of: showCamera) { _, isShowing in
      if !isShowing, capturedImages.isEmpty, stage == .capture {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          stage = .selectMode
          stageAppeared = false
        }
        triggerStageAppearance()
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
          ForEach(Array(GroceryEntryMode.allCases.enumerated()), id: \.element) { index, mode in
            modeCard(mode, staggerIndex: index)
          }
        }

        Spacer(minLength: AppTheme.Space.xl)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .onAppear { triggerStageAppearance() }
  }

  private func modeCard(_ mode: GroceryEntryMode, staggerIndex: Int) -> some View {
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
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000)
        showCamera = true
      }
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
      let delayNanoseconds: UInt64 = reduceMotion ? 500_000_000 : 1_300_000_000
      try? await Task.sleep(nanoseconds: delayNanoseconds)

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
      Task {
        try? await Task.sleep(nanoseconds: reduceMotion ? 800_000_000 : 1_600_000_000)
        dismiss()
      }
    }
  }

  // MARK: - Navigation Helpers

  private func advanceToCaptureOrReview(mode: GroceryEntryMode) {
    switch mode {
    case .photo, .receipt:
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        stage = .capture
        stageAppeared = false
      }
    case .manual:
      selectedIngredientIDs = []
      showIngredientPicker = true
    }
  }

  private func onIngredientPickerDismiss() {
    guard !selectedIngredientIDs.isEmpty else {
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
      stageAppeared = true
    } else {
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 50_000_000)
        withAnimation(AppMotion.cardSpring) {
          stageAppeared = true
        }
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
