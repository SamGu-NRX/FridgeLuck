import SwiftUI
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "IngredientReviewView")

/// Review detected ingredients: confirm, remove, correct, or add manually.
/// Then proceed to recipe recommendations.
struct IngredientReviewView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State var detections: [Detection]
  let nutritionLabelOutcome: NutritionLabelParseOutcome?
  let scanProvenance: ScanProvenance
  let scanDiagnostics: ScanDiagnostics?
  let fridgeImage: UIImage?
  let scopedDependencies: Dependencies?

  struct Dependencies {
    let makeRecommendationEngine: () -> RecommendationEngine
    let suggestedCorrection: (_ visionLabel: String) -> Int64?
    let recordSuggestionShown: () -> Void
    let fetchAllIngredients: () throws -> [Ingredient]
    let recordCorrection: (_ visionLabel: String, _ correctedIngredientID: Int64) -> Void
    let recordSuggestionOutcome: (_ accepted: Bool) -> Void
    let ingestInventoryFromScan:
      (
        _ detections: [Detection],
        _ confirmedIngredientIDs: Set<Int64>,
        _ selectedIngredientByDetection: [UUID: Int64],
        _ sourceRef: String
      ) throws -> Void
  }

  var dependencies: Dependencies {
    if let scopedDependencies { return scopedDependencies }
    return Dependencies(
      makeRecommendationEngine: { deps.makeRecommendationEngine() },
      suggestedCorrection: { visionLabel in
        deps.learningService.suggestedCorrection(for: visionLabel)
      },
      recordSuggestionShown: {
        deps.learningService.recordSuggestionShown()
      },
      fetchAllIngredients: {
        try deps.ingredientRepository.fetchAll()
      },
      recordCorrection: { visionLabel, correctedIngredientID in
        deps.learningService.recordCorrection(
          visionLabel: visionLabel,
          correctedIngredientId: correctedIngredientID
        )
      },
      recordSuggestionOutcome: { accepted in
        deps.learningService.recordSuggestionOutcome(accepted: accepted)
      },
      ingestInventoryFromScan: {
        detections,
        confirmedIngredientIDs,
        selectedIngredientByDetection,
        sourceRef
        in
        _ = try deps.inventoryIntakeService.ingestConfirmedScan(
          detections: detections,
          confirmedIngredientIDs: confirmedIngredientIDs,
          selectedIngredientByDetection: selectedIngredientByDetection,
          sourceRef: sourceRef
        )
      }
    )
  }

  @State private var confirmedIds: Set<Int64> = []
  @State private var showSheetMode: IngredientSheetMode?
  @State private var navigateToResults = false
  @State private var allIngredients: [Ingredient] = []
  @State private var ingredientByID: [Int64: Ingredient] = [:]
  @State private var categorizedResults = ConfidenceRouter.CategorizedResults(
    confirmed: [],
    needsConfirmation: [],
    possible: []
  )
  @State private var selectedIngredientForDetail: Ingredient?
  @State private var showFridgePhoto = false

  @State private var selectedIngredientForDetection: [UUID: Int64] = [:]
  @State private var suggestedOutcomeByDetection: [UUID: Bool] = [:]
  @State private var didInitialize = false
  @State private var inventorySourceRef = "scan-review:\(UUID().uuidString)"

  // MARK: - Spotlight Tutorial State
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""
  @AppStorage(TutorialStorageKeys.hasSeenReviewSpotlight) private var hasSeenReviewSpotlight = false
  @State private var reviewSpotlight = SpotlightCoordinator()
  @State private var showReviewSpotlight = false
  @State private var reviewSpotlightStepID: String?
  @State private var isInitialAutoTour = true

  init(
    detections: [Detection],
    nutritionLabelOutcome: NutritionLabelParseOutcome? = nil,
    scanProvenance: ScanProvenance = .realScan,
    scanDiagnostics: ScanDiagnostics? = nil,
    fridgeImage: UIImage? = nil,
    dependencies: Dependencies? = nil
  ) {
    self._detections = State(initialValue: detections)
    self.nutritionLabelOutcome = nutritionLabelOutcome
    self.scanProvenance = scanProvenance
    self.scanDiagnostics = scanDiagnostics
    self.fridgeImage = fridgeImage
    self.scopedDependencies = dependencies
  }

  enum IngredientSheetMode: Identifiable {
    case addManual
    case correct(Detection)

    var id: String {
      switch self {
      case .addManual:
        return "add-manual"
      case .correct(let detection):
        return "correct-\(detection.id.uuidString)"
      }
    }

    var title: String {
      switch self {
      case .addManual:
        return "Add Ingredient"
      case .correct(let detection):
        return "Correct \(detection.label)"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { scrollProxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            IngredientReviewSummarySection(
              confirmedCount: confirmedIds.count,
              categorizedConfirmedCount: categorized.confirmed.count,
              categorizedNeedsConfirmationCount: categorized.needsConfirmation.count,
              categorizedPossibleCount: categorized.possible.count,
              unresolvedCount: unresolvedCount,
              confirmationCompletion: confirmationCompletion,
              reduceMotion: reduceMotion,
              confidencePillText: confidenceHealthPill().text,
              confidencePillKind: confidenceHealthPill().kind,
              fridgeImage: fridgeImage,
              onOpenFridgePhoto: { showFridgePhoto = true }
            )
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

            IngredientReviewNutritionSection(nutritionLabelOutcome: nutritionLabelOutcome)
              .padding(.horizontal, AppTheme.Space.page)

            bulkActionSection
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)
              .id("bulkActions")
              .spotlightAnchor("bulkActions")

            FLWaveDivider()
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)

            IngredientReviewConfirmedSection(
              detections: categorized.confirmed,
              confirmedIds: confirmedIds,
              onInfo: { ingredientID in
                if let ingredient = ingredient(for: ingredientID) {
                  selectedIngredientForDetail = ingredient
                }
              },
              onToggle: toggleIngredient
            )
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)
            .id("autoDetected")
            .spotlightAnchor("autoDetected")

            if !categorized.confirmed.isEmpty && !categorized.needsConfirmation.isEmpty {
              FLWaveDivider()
                .padding(.horizontal, AppTheme.Space.page)
                .padding(.bottom, AppTheme.Space.lg)
            }

            IngredientReviewNeedsConfirmationSection(
              detections: categorized.needsConfirmation,
              selectedIngredientId: selectedIngredient,
              optionsForDetection: candidateOptions,
              onChoose: choose,
              onChooseAnother: { detection in
                showSheetMode = .correct(detection)
              },
              onClear: clearSelection,
              onInfo: { detection in
                if let ingredient = ingredient(
                  for: selectedIngredient(for: detection) ?? detection.ingredientId)
                {
                  selectedIngredientForDetail = ingredient
                }
              }
            )
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)
            .id("needsConfirmation")
            .spotlightAnchor("needsConfirmation")

            if !categorized.needsConfirmation.isEmpty && !categorized.possible.isEmpty {
              FLWaveDivider()
                .padding(.horizontal, AppTheme.Space.page)
                .padding(.bottom, AppTheme.Space.lg)
            }

            IngredientReviewPossibleSection(
              detections: categorized.possible,
              confirmedIds: confirmedIds,
              onInfo: { ingredientID in
                if let ingredient = ingredient(for: ingredientID) {
                  selectedIngredientForDetail = ingredient
                }
              },
              onToggle: toggleIngredient
            )
            .padding(.horizontal, AppTheme.Space.page)
          }
          .padding(.top, AppTheme.Space.md)
          .padding(.bottom, AppTheme.Space.lg)
        }
        .onAppear {
          reviewSpotlight.onScrollToAnchor = { anchorID in
            guard anchorID != "confidenceLevels" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              withAnimation(AppMotion.spotlightMove) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
              }
            }
          }
        }
      }

      IngredientReviewBottomBar(
        confirmedCount: confirmedIds.count,
        unresolvedCount: unresolvedCount,
        reduceMotion: reduceMotion,
        onFindRecipes: {
          logger.info(
            "Find recipes tapped. confirmed=\(confirmedIds.count, privacy: .public), unresolved=\(unresolvedCount, privacy: .public)"
          )
          do {
            try dependencies.ingestInventoryFromScan(
              detections,
              confirmedIds,
              selectedIngredientForDetection,
              inventorySourceRef
            )
            logger.info("Inventory intake from scan review succeeded.")
          } catch {
            logger.error(
              "Inventory intake from scan review failed: \(error.localizedDescription, privacy: .public)"
            )
          }
          flushLearningTelemetry()
          navigateToResults = true
        }
      )
      .id("findRecipes")
      .spotlightAnchor("findRecipes")
    }
    .onPreferenceChange(SpotlightAnchorKey.self) { newAnchors in
      var merged = reviewSpotlight.anchors
      for (anchorID, rect) in newAnchors where isUsableAnchorRect(rect) {
        merged[anchorID] = rect
      }
      reviewSpotlight.anchors = merged
    }
    .overlay {
      if showReviewSpotlight, let steps = reviewSpotlight.activeSteps {
        SpotlightTutorialOverlay(
          steps: steps,
          anchors: reviewSpotlight.anchors,
          isPresented: Binding(
            get: { showReviewSpotlight },
            set: { isPresented in
              if !isPresented {
                showReviewSpotlight = false
                reviewSpotlight.activeSteps = nil
                reviewSpotlightStepID = nil
              }
            }
          ),
          onScrollToAnchor: reviewSpotlight.onScrollToAnchor,
          onStepChange: { step in
            reviewSpotlightStepID = step.id
          }
        )
        .ignoresSafeArea()
      }
    }
    .navigationTitle("Review Ingredients")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(showReviewSpotlight)
    .flPageBackground()
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      if !showReviewSpotlight || reviewSpotlightStepID == "review_toolbar_add" {
        ToolbarItem(placement: .topBarTrailing) {
          toolbarAddButton()
            .spotlightAnchor("toolbarAdd")
        }
      }
      if hasSeenReviewSpotlight && isInitialAutoTour && !showReviewSpotlight {
        ToolbarItem(placement: .topBarLeading) {
          replayTourButton
        }
      }
    }
    .sheet(item: $showSheetMode) { mode in
      switch mode {
      case .addManual:
        IngredientPickerView(
          title: mode.title,
          seedIngredients: allIngredients,
          onPickSingle: { ingredient in
            addManualIngredient(ingredient)
          }
        )
        .environmentObject(deps)
      case .correct(let detection):
        IngredientPickerView(
          title: mode.title,
          seedIngredients: candidateSeedIngredients(for: detection),
          onPickSingle: { ingredient in
            applyManualCorrection(ingredient: ingredient, detection: detection)
          }
        )
        .environmentObject(deps)
      }
    }
    .sheet(item: $selectedIngredientForDetail) { ingredient in
      IngredientDetailSheet(ingredient: ingredient)
    }
    .sheet(isPresented: $showFridgePhoto) {
      if let fridgeImage {
        FridgePhotoViewer(image: fridgeImage)
      }
    }
    .navigationDestination(isPresented: $navigateToResults) {
      RecipeResultsView(
        ingredientIds: confirmedIds,
        ingredientNames: confirmedIngredientNames(),
        fridgePhoto: fridgeImage,
        scanConfidenceScore: averageConfirmedDetectionConfidence(),
        engine: dependencies.makeRecommendationEngine()
      )
    }
    .onAppear {
      guard !didInitialize else { return }
      didInitialize = true
      loadAllIngredients()
      refreshCategorization(seedSuggestions: true)
      markIngredientReviewQuestIfNeeded()
    }
    .onChange(of: detectionIDs) { _, _ in
      refreshCategorization(seedSuggestions: false)
    }
    .task(id: shouldAutoPresentReviewSpotlight) {
      guard shouldAutoPresentReviewSpotlight else { return }
      let delay = reduceMotion ? 0.3 : 0.8
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard shouldAutoPresentReviewSpotlight else { return }
      presentReviewSpotlight()
    }
  }

  // MARK: - Review Spotlight

  private var shouldAutoPresentReviewSpotlight: Bool {
    guard !hasSeenReviewSpotlight else { return false }
    guard reviewSpotlight.activeSteps == nil else { return false }
    guard !showReviewSpotlight else { return false }
    return isAnchorReady("confidenceLevels")
  }

  private func isAnchorReady(_ anchorID: String) -> Bool {
    guard let rect = reviewSpotlight.anchors[anchorID] else { return false }
    return isUsableAnchorRect(rect)
  }

  private func isUsableAnchorRect(_ rect: CGRect) -> Bool {
    guard !rect.isEmpty, !rect.isNull, !rect.isInfinite else { return false }
    guard rect.width > 0, rect.height > 0 else { return false }
    return rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private func presentReviewSpotlight() {
    guard reviewSpotlight.activeSteps == nil else { return }
    reviewSpotlight.activeSteps = SpotlightStep.ingredientReview
    showReviewSpotlight = true
    reviewSpotlightStepID = SpotlightStep.ingredientReview.first?.id
    hasSeenReviewSpotlight = true
  }

  private func toolbarAddButton() -> some View {
    Button {
      showSheetMode = .addManual
    } label: {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(AppTheme.accent)
        .symbolRenderingMode(.hierarchical)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add ingredient manually")
  }

  private var replayTourButton: some View {
    Button {
      isInitialAutoTour = false
      presentReviewSpotlight()
    } label: {
      HStack(spacing: AppTheme.Space.xxs) {
        Image(systemName: "arrow.counterclockwise")
          .font(.system(size: 12, weight: .semibold))
        Text("Replay tour")
          .font(.system(size: 13, weight: .medium))
      }
      .foregroundStyle(AppTheme.accent)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Replay guided tour")
  }

  // MARK: - Categorization

  private var categorized: ConfidenceRouter.CategorizedResults {
    categorizedResults
  }

  private var detectionIDs: [UUID] {
    detections.map(\.id)
  }

  private var unresolvedCount: Int {
    categorized.needsConfirmation.filter { selectedIngredient(for: $0) == nil }.count
  }

  private var confirmationCompletion: Double {
    let total = max(1, categorized.needsConfirmation.count)
    return Double(total - unresolvedCount) / Double(total)
  }

  private func refreshCategorization(seedSuggestions: Bool) {
    let results = ConfidenceRouter.categorize(detections)
    categorizedResults = results
    logger.debug(
      "Categorizing detections. confirmed=\(results.confirmed.count, privacy: .public), needsConfirmation=\(results.needsConfirmation.count, privacy: .public), possible=\(results.possible.count, privacy: .public)"
    )

    guard seedSuggestions else { return }

    for detection in results.confirmed {
      confirmedIds.insert(detection.ingredientId)
    }

    for detection in results.needsConfirmation {
      if let suggested = dependencies.suggestedCorrection(detection.originalVisionLabel) {
        dependencies.recordSuggestionShown()
        selectedIngredientForDetection[detection.id] = suggested
        confirmedIds.insert(suggested)
        suggestedOutcomeByDetection[detection.id] = true
      }
    }
  }

  private func loadAllIngredients() {
    let ingredients = (try? dependencies.fetchAllIngredients()) ?? []
    allIngredients = ingredients
    ingredientByID = Dictionary(
      uniqueKeysWithValues: ingredients.compactMap { ingredient -> (Int64, Ingredient)? in
        guard let id = ingredient.id else { return nil }
        return (id, ingredient)
      }
    )
  }

  private func ingredient(for id: Int64) -> Ingredient? {
    ingredientByID[id]
  }

  private func displayName(for id: Int64) -> String {
    ingredient(for: id)?.displayName
      ?? IngredientLexicon.displayName(for: id)
  }

  private func confirmedIngredientNames() -> [String] {
    confirmedIds
      .map { ingredient(for: $0)?.displayName ?? IngredientLexicon.displayName(for: $0) }
      .sorted()
  }

  private func averageConfirmedDetectionConfidence() -> Double? {
    let confirmedDetections = detections.filter { detection in
      let resolvedIngredientID =
        selectedIngredientForDetection[detection.id] ?? detection.ingredientId
      return confirmedIds.contains(resolvedIngredientID)
    }
    guard !confirmedDetections.isEmpty else { return nil }

    let sum = confirmedDetections.reduce(0.0) { partial, detection in
      partial + max(0, min(Double(detection.confidence), 1.0))
    }
    return sum / Double(confirmedDetections.count)
  }

  private func confidenceHealthPill() -> (text: String, kind: FLStatusPill.Kind) {
    if categorized.needsConfirmation.isEmpty {
      return ("All clear", .positive)
    }
    if unresolvedCount == 0 {
      return ("Confirmation complete", .positive)
    }
    return ("\(unresolvedCount) need review", .warning)
  }

  // MARK: - Bulk Actions (lighter, no card wrapper)

  private var bulkActionSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.sm) {
        Button(action: selectAllAutoDetected) {
          Label("Select Auto", systemImage: "checkmark.seal.fill")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)

        Button(action: clearUncertainSelections) {
          Label("Clear Uncertain", systemImage: "xmark.circle")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)

        Spacer()

        Button {
          showSheetMode = .addManual
        } label: {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "plus")
              .font(.system(size: 11, weight: .bold))
            Text("Add")
              .font(.system(.caption, design: .serif, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, AppTheme.Space.sm)
          .padding(.vertical, AppTheme.Space.chipVertical)
          .background(
            AppTheme.accent,
            in: Capsule()
          )
          .shadow(color: AppTheme.accent.opacity(0.22), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(FLAddChipButtonStyle())
      }
    }
  }

  // MARK: - Actions

  private func toggleIngredient(_ id: Int64) {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      if confirmedIds.contains(id) {
        confirmedIds.remove(id)
      } else {
        confirmedIds.insert(id)
      }
    }
  }

  private func selectAllAutoDetected() {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      for detection in categorized.confirmed {
        confirmedIds.insert(detection.ingredientId)
      }
    }
  }

  private func clearUncertainSelections() {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      for detection in categorized.needsConfirmation {
        if let chosen = selectedIngredient(for: detection) {
          confirmedIds.remove(chosen)
        }
        selectedIngredientForDetection.removeValue(forKey: detection.id)
        suggestedOutcomeByDetection.removeValue(forKey: detection.id)
      }

      for detection in categorized.possible {
        confirmedIds.remove(detection.ingredientId)
      }
    }
  }

  private func addManualIngredient(_ ingredient: Ingredient) {
    guard let id = ingredient.id else { return }

    if !detections.contains(where: { $0.ingredientId == id }) {
      let detection = Detection(
        ingredientId: id,
        label: ingredient.displayName,
        confidence: 1.0,
        source: .manual,
        originalVisionLabel: ingredient.name,
        alternatives: []
      )
      detections.append(detection)
    }

    confirmedIds.insert(id)
  }

  private func applyManualCorrection(ingredient: Ingredient, detection: Detection) {
    guard let id = ingredient.id else { return }
    choose(
      option: DetectionAlternative(
        ingredientId: id,
        label: ingredient.displayName,
        confidence: nil
      ),
      for: detection
    )
  }

  private func selectedIngredient(for detection: Detection) -> Int64? {
    selectedIngredientForDetection[detection.id]
  }

  private func clearSelection(for detection: Detection) {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      if let previous = selectedIngredient(for: detection) {
        confirmedIds.remove(previous)
      }
      selectedIngredientForDetection.removeValue(forKey: detection.id)
    }

    if let suggestion = dependencies.suggestedCorrection(detection.originalVisionLabel) {
      suggestedOutcomeByDetection[detection.id] = (suggestion == detection.ingredientId)
    }
  }

  private func choose(option: DetectionAlternative, for detection: Detection) {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      if let previous = selectedIngredient(for: detection) {
        confirmedIds.remove(previous)
      }

      selectedIngredientForDetection[detection.id] = option.ingredientId
      confirmedIds.insert(option.ingredientId)
    }

    if option.ingredientId != detection.ingredientId {
      dependencies.recordCorrection(detection.originalVisionLabel, option.ingredientId)
      logger.debug(
        "User corrected detection. original=\(detection.label, privacy: .public), selected=\(option.label, privacy: .public)"
      )
    }

    if let suggestion = dependencies.suggestedCorrection(detection.originalVisionLabel) {
      suggestedOutcomeByDetection[detection.id] = (option.ingredientId == suggestion)
    }
  }

  private func flushLearningTelemetry() {
    let sampleCount = suggestedOutcomeByDetection.count
    for (_, accepted) in suggestedOutcomeByDetection {
      dependencies.recordSuggestionOutcome(accepted)
    }
    suggestedOutcomeByDetection.removeAll()
    logger.debug("Flushed learning telemetry outcomes. samples=\(sampleCount, privacy: .public)")
  }

  private func candidateOptions(for detection: Detection) -> [DetectionAlternative] {
    var options: [DetectionAlternative] = []

    if let suggested = dependencies.suggestedCorrection(detection.originalVisionLabel) {
      options.append(
        DetectionAlternative(
          ingredientId: suggested,
          label: displayName(for: suggested),
          confidence: nil
        )
      )
    }

    options.append(
      DetectionAlternative(
        ingredientId: detection.ingredientId,
        label: displayName(for: detection.ingredientId),
        confidence: detection.confidence
      )
    )

    options.append(contentsOf: detection.alternatives)

    var deduped: [DetectionAlternative] = []
    var seen = Set<Int64>()

    for option in options {
      if seen.insert(option.ingredientId).inserted {
        let normalized = DetectionAlternative(
          ingredientId: option.ingredientId,
          label: displayName(for: option.ingredientId),
          confidence: option.confidence
        )
        deduped.append(normalized)
      }
      if deduped.count >= 5 {
        break
      }
    }

    return deduped
  }

  private func candidateSeedIngredients(for detection: Detection) -> [Ingredient] {
    let ids = candidateOptions(for: detection).map(\.ingredientId)
    let seeded = ids.compactMap { ingredientByID[$0] }
    return seeded.isEmpty ? allIngredients : seeded
  }

  private func markIngredientReviewQuestIfNeeded() {
    var progress = TutorialProgress(storageString: tutorialStorageString)
    guard !progress.isCompleted(.ingredientReview) else { return }
    progress.markCompleted(.ingredientReview)
    tutorialStorageString = progress.storageString
  }
}

// MARK: - Fridge Photo Viewer

struct FridgePhotoViewer: View {
  @Environment(\.dismiss) private var dismiss
  let image: UIImage
  @State private var scale: CGFloat = 1.0
  @State private var lastScale: CGFloat = 1.0

  var body: some View {
    NavigationStack {
      GeometryReader { geo in
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(
              width: geo.size.width * scale,
              height: geo.size.height * scale
            )
            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            .gesture(
              MagnifyGesture()
                .onChanged { value in
                  scale = max(1.0, min(lastScale * value.magnification, 4.0))
                }
                .onEnded { _ in
                  lastScale = scale
                  if scale < 1.1 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                      scale = 1.0
                      lastScale = 1.0
                    }
                  }
                }
            )
            .onTapGesture(count: 2) {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if scale > 1.1 {
                  scale = 1.0
                  lastScale = 1.0
                } else {
                  scale = 2.5
                  lastScale = 2.5
                }
              }
            }
        }
      }
      .background(Color.black)
      .navigationTitle("Fridge Photo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .foregroundStyle(.white)
        }
      }
      .toolbarBackground(.black, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
  }
}
