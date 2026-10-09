import FLFeatureLogic
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

  // Real analysis and commit state.
  @State private var analysisTask: Task<Void, Never>?
  @State private var analysisFailure: String?
  @State private var commitTask: Task<Void, Never>?
  @State private var commitFailure: String?
  @State private var sessionRef: String?
  @State private var committedItems: [GroceryPendingItem] = []
  @State private var committedDuplicates = false
  /// Which review item the ingredient picker is choosing a food for; nil means the
  /// picker is in add-more mode.
  @State private var identityPickTarget: UUID?

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

  private var activeMode: UpdateGroceriesLaunchMode {
    selectedMode ?? launchMode
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
            reviewView
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
    .alert(
      "Couldn't add these",
      isPresented: Binding(
        get: { commitFailure != nil },
        set: { if !$0 { commitFailure = nil } }
      )
    ) {
      Button("Try Again") { commitGroceries() }
      Button("OK", role: .cancel) {}
    } message: {
      Text(commitFailure ?? "")
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
      if let target = identityPickTarget {
        IngredientPickerView(
          title: "Which food is this?",
          onPickSingle: { ingredient in
            applyPickedIdentity(ingredient, to: target)
            identityPickTarget = nil
            showIngredientPicker = false
          }
        )
      } else {
        IngredientPickerView(
          title: "Add Ingredients",
          selectedIDs: $selectedIngredientIDs
        )
      }
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

  @ViewBuilder
  private var analyzeView: some View {
    if let analysisFailure {
      analyzeFailureView(message: analysisFailure)
    } else {
      ScanAnalyzingView(
        capturedImage: capturedImage,
        fallbackStateText: nil,
        reduceMotion: reduceMotion,
        title: "Identifying groceries",
        subtitle:
          (selectedMode ?? launchMode) == .receipt
          ? "Reading your receipt, line by line."
          : "Matching items and estimating quantities."
      )
      .padding(.horizontal, AppTheme.Space.page)
      .task {
        startAnalysis()
      }
    }
  }

  private func analyzeFailureView(message: String) -> some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer()

      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "questionmark.circle")
          .font(.system(size: 40, weight: .medium))
          .foregroundStyle(AppTheme.oat.opacity(0.6))

        Text(message)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        VStack(spacing: AppTheme.Space.sm) {
          FLPrimaryButton("Try Again", systemImage: "arrow.clockwise", isEnabled: true) {
            analysisFailure = nil
            withAnimation(reduceMotion ? nil : AppMotion.gentle) {
              stage = .analyze
              stageAppeared = false
            }
          }

          Button {
            showIngredientPicker = true
          } label: {
            HStack(spacing: AppTheme.Space.sm) {
              Image(systemName: "list.star")
              Text("Add items manually instead")
            }
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(FLPressableButtonStyle())
        }
        .padding(.top, AppTheme.Space.xs)
      }
      .padding(AppTheme.Space.lg)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
      )
      .padding(.horizontal, AppTheme.Space.page)

      Spacer()
    }
  }

  // MARK: - Review

  private var reviewView: some View {
    GroceryReviewSection(
      items: $pendingItems,
      isCommitting: isCommitting,
      onCommit: commitGroceries,
      onAddMore: {
        identityPickTarget = nil
        selectedIngredientIDs = []
        showIngredientPicker = true
      },
      onPickIdentity: { itemID in
        identityPickTarget = itemID
        showIngredientPicker = true
      }
    )
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

          Text(
            committedDuplicates
              ? "These were already in your kitchen, so nothing was added twice."
              : "Your virtual fridge has been updated."
          )
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
        }

        if !committedItems.isEmpty {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            ForEach(committedItems.prefix(6)) { item in
              HStack(spacing: AppTheme.Space.sm) {
                Image(systemName: "checkmark")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(AppTheme.sage)

                Text(item.ingredientName)
                  .font(AppTheme.Typography.bodyMedium)
                  .foregroundStyle(AppTheme.textPrimary)
                  .lineLimit(1)

                Spacer()

                if let grams = item.quantityGrams {
                  Text(committedAmountSummary(for: item, grams: grams))
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.textSecondary)
                }
              }
            }

            if committedItems.count > 6 {
              Text("+\(committedItems.count - 6) more")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .padding(AppTheme.Space.md)
          .background(
            AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .padding(.horizontal, AppTheme.Space.page)
        }
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
    .onAppear {
      scheduleSuccessDismiss()
    }
  }

  private func committedAmountSummary(for item: GroceryPendingItem, grams: Double) -> String {
    var parts = ["\(Int(grams.rounded()))g"]
    switch item.storageLocation {
    case .fridge: parts.append("Fridge")
    case .pantry: parts.append("Pantry")
    case .freezer: parts.append("Freezer")
    case .unknown: break
    }
    if item.quantityProvenance == .estimate {
      parts.append("est.")
    }
    return parts.joined(separator: " \u{00B7} ")
  }

  // MARK: - Analysis

  private func startAnalysis() {
    guard let image = capturedImage, let cgImage = image.cgImage, analysisTask == nil else {
      return
    }
    analysisFailure = nil

    let mode: GroceryCaptureAnalyzer.Mode =
      activeMode == .receipt ? .receipt : .photo

    analysisTask = Task {
      do {
        let items = try await makeAnalyzer().analyze(image: cgImage, mode: mode)
        guard !Task.isCancelled else { return }

        if items.isEmpty {
          analysisFailure =
            "No foods found yet. Try again with the item filling more of the frame, or add them manually."
          return
        }

        pendingItems = items
        sessionRef = GroceryIntakeNormalizer.newSessionRef()

        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          stage = .review
          stageAppeared = false
        }
        triggerStageAppearance()
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Grocery analysis failed: \(error.localizedDescription)")
        analysisFailure =
          "Something went wrong reading the photo. Try again, or add the items manually."
      }
      analysisTask = nil
    }
  }

  /// Production wiring: the app's VisionService for recognition, the ingredient catalog for
  /// identity, and the honest-amount estimator for unit masses.
  private func makeAnalyzer() -> GroceryCaptureAnalyzer {
    let vision = deps.visionService
    let repository = deps.ingredientRepository

    return GroceryCaptureAnalyzer(
      passes: .init(
        photo: { cgImage in
          let result = try await vision.scan(image: cgImage)
          return (
            detections: result.detections.map { detection in
              GroceryDetectionInput(
                ingredientId: detection.ingredientId,
                label: detection.label,
                confidence: detection.confidence,
                count: 1,
                alternatives: detection.alternatives.map {
                  GroceryAlternative(id: $0.ingredientId, name: $0.label)
                }
              )
            },
            ocrText: result.ocrText
          )
        },
        receipt: { cgImage in
          try await vision.recognizeTextLines(image: cgImage)
            .compactMap(\.candidates.first)
        }
      ),
      glue: .init(
        resolveLine: { text in
          if let match = IngredientLexicon.resolveFromTextDetailed(text) {
            let confidence =
              match.kind == .exact
              ? Double(ConfidenceRouter.Thresholds.ocrExactAuto)
              : Double(ConfidenceRouter.Thresholds.ocrExactConfirmMin)
            return (match.ingredientId, confidence)
          }
          if let id = IngredientIdentityResolution.resolveTextFromCatalog(
            text,
            catalogName: repository.resolve,
            catalogTokens: repository.resolveFromText
          ) {
            return (id, Double(ConfidenceRouter.Thresholds.ocrFuzzyConfirmMin))
          }
          return nil
        },
        alternativesFor: { text in
          let query =
            GroceryIntakeNormalizer.displayTitle(text)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 }
            .first ?? ""
          guard !query.isEmpty else { return [] }
          return repository.search(query: query, limit: 3)
            .compactMap { ingredient in
              guard let id = ingredient.id else { return nil }
              return GroceryAlternative(id: id, name: ingredient.displayName)
            }
        },
        displayName: { id in
          repository.displayName(for: id) ?? IngredientLexicon.displayName(for: id)
        },
        estimateUnitGrams: { id in
          guard let ingredient = (try? repository.fetch(id: id)) ?? nil else { return nil }
          return InventoryIntakeService.estimateGramsIfKnown(forName: ingredient.displayName)
        },
        estimateGramsForName: { name in
          InventoryIntakeService.estimateGramsIfKnown(forName: name)
        },
        inferLocation: { id in
          guard let ingredient = (try? repository.fetch(id: id)) ?? nil else { return .unknown }
          return InventoryIntakeService.inferLocation(forName: ingredient.displayName)
        }
      )
    )
  }

  // MARK: - Identity Correction

  private func applyPickedIdentity(_ ingredient: Ingredient, to itemID: UUID) {
    guard let id = ingredient.id,
      let index = pendingItems.firstIndex(where: { $0.id == itemID })
    else { return }

    let estimatedGrams = InventoryIntakeService.estimateGramsIfKnown(
      forName: ingredient.displayName)
    let location = InventoryIntakeService.inferLocation(forName: ingredient.displayName)

    pendingItems[index].replaceIdentity(
      ingredientId: id,
      name: ingredient.displayName,
      estimatedGrams: estimatedGrams
    )
    if pendingItems[index].storageLocation == .unknown {
      pendingItems[index].storageLocation = location
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
    analysisTask?.cancel()
    analysisTask = nil
    commitTask?.cancel()
    commitTask = nil
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
    // Single-pick (identity correction) resolves in applyPickedIdentity.
    guard identityPickTarget == nil else { return }

    guard !selectedIngredientIDs.isEmpty else {
      if launchMode.isDirectEntry, pendingItems.isEmpty {
        dismiss()
      }
      return
    }

    let ingredients = (try? deps.ingredientRepository.fetch(ids: selectedIngredientIDs)) ?? []
    let newItems = ingredients.compactMap { ingredient -> GroceryPendingItem? in
      guard let id = ingredient.id else { return nil }
      let estimatedGrams = InventoryIntakeService.estimateGramsIfKnown(
        forName: ingredient.displayName)
      return GroceryPendingItem(
        ingredientId: id,
        ingredientName: ingredient.displayName,
        quantityGrams: estimatedGrams,
        storageLocation: InventoryIntakeService.inferLocation(forName: ingredient.displayName),
        confidenceScore: 1.0,
        source: .manual,
        isConfirmed: true,
        quantityProvenance: estimatedGrams.map { _ in .estimate }
      )
    }

    let existingIDs = Set(pendingItems.compactMap(\.ingredientId))
    let uniqueNew = newItems.filter { !existingIDs.contains($0.ingredientId ?? -1) }
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
    guard !confirmed.isEmpty, confirmed.allSatisfy(\.isResolvedForCommit) else { return }

    if sessionRef == nil {
      sessionRef = GroceryIntakeNormalizer.newSessionRef()
    }
    guard let sessionRef else { return }

    isCommitting = true
    commitFailure = nil

    commitTask = Task {
      let groceryItems = confirmed.map { item in
        InventoryIntakeService.GroceryIngestItem(
          ingredientId: item.ingredientId!,
          quantityGrams: item.quantityGrams!,
          storageLocation: item.storageLocation,
          confidenceScore: item.confidenceScore,
          source: item.source,
          quantityProvenance: item.quantityProvenance ?? .estimate
        )
      }

      do {
        let summary = try deps.inventoryIntakeService.ingestGrocerySession(
          items: groceryItems,
          sourceRef: sessionRef
        )

        committedItems = confirmed
        committedDuplicates = summary.skippedAsDuplicate

        withAnimation(reduceMotion ? nil : AppMotion.celebration) {
          showSuccess = true
        }
      } catch {
        logger.error("Failed to commit groceries: \(error.localizedDescription)")
        commitFailure =
          "Your kitchen wasn't updated — nothing was saved. Check your connection and try again."
      }

      isCommitting = false
    }
  }
}
