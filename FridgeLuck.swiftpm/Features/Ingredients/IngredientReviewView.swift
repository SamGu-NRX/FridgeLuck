import SwiftUI

/// Review detected ingredients: confirm, remove, correct, or add manually.
/// Then proceed to recipe recommendations.
struct IngredientReviewView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State var detections: [Detection]
  let nutritionLabelOutcome: NutritionLabelParseOutcome?
  let scanProvenance: ScanProvenance
  let scanDiagnostics: ScanDiagnostics?

  @State private var confirmedIds: Set<Int64> = []
  @State private var showSheetMode: IngredientSheetMode?
  @State private var navigateToResults = false
  @State private var allIngredients: [Ingredient] = []
  @State private var selectedIngredientForDetail: Ingredient?

  @State private var selectedIngredientForDetection: [UUID: Int64] = [:]
  @State private var suggestedOutcomeByDetection: [UUID: Bool] = [:]
  @State private var didInitialize = false

  init(
    detections: [Detection],
    nutritionLabelOutcome: NutritionLabelParseOutcome? = nil,
    scanProvenance: ScanProvenance = .realScan,
    scanDiagnostics: ScanDiagnostics? = nil
  ) {
    self._detections = State(initialValue: detections)
    self.nutritionLabelOutcome = nutritionLabelOutcome
    self.scanProvenance = scanProvenance
    self.scanDiagnostics = scanDiagnostics
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
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          summarySection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          nutritionLabelSection
            .padding(.horizontal, AppTheme.Space.page)

          bulkActionSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          confirmedSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          if !categorized.confirmed.isEmpty && !categorized.needsConfirmation.isEmpty {
            FLWaveDivider()
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)
          }

          needsConfirmationSection
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          if !categorized.needsConfirmation.isEmpty && !categorized.possible.isEmpty {
            FLWaveDivider()
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)
          }

          possibleSection
            .padding(.horizontal, AppTheme.Space.page)
        }
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.lg)
      }

      bottomBar
    }
    .navigationTitle("Review Ingredients")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showSheetMode = .addManual
        } label: {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(AppTheme.accent)
            .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("Add ingredient manually")
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
    .navigationDestination(isPresented: $navigateToResults) {
      RecipeResultsView(
        ingredientIds: confirmedIds,
        engine: deps.makeRecommendationEngine()
      )
    }
    .onAppear {
      guard !didInitialize else { return }
      didInitialize = true
      loadAllIngredients()
      categorizeDetections()
    }
  }

  // MARK: - Categorization

  private var categorized: ConfidenceRouter.CategorizedResults {
    ConfidenceRouter.categorize(detections)
  }

  private var unresolvedCount: Int {
    categorized.needsConfirmation.filter { selectedIngredient(for: $0) == nil }.count
  }

  private var confirmationCompletion: Double {
    let total = max(1, categorized.needsConfirmation.count)
    return Double(total - unresolvedCount) / Double(total)
  }

  private func categorizeDetections() {
    let results = categorized

    for detection in results.confirmed {
      confirmedIds.insert(detection.ingredientId)
    }

    for detection in results.needsConfirmation {
      if let suggested = deps.learningService.suggestedCorrection(
        for: detection.originalVisionLabel)
      {
        deps.learningService.recordSuggestionShown()
        selectedIngredientForDetection[detection.id] = suggested
        confirmedIds.insert(suggested)
        suggestedOutcomeByDetection[detection.id] = true
      }
    }
  }

  private func loadAllIngredients() {
    allIngredients = (try? deps.ingredientRepository.fetchAll()) ?? []
  }

  private func ingredient(for id: Int64) -> Ingredient? {
    allIngredients.first(where: { $0.id == id })
  }

  private func displayName(for id: Int64) -> String {
    ingredient(for: id)?.displayName
      ?? IngredientLexicon.displayName(for: id)
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

  // MARK: - Summary Section (card-free, editorial)

  private var summarySection: some View {
    let telemetry = deps.learningService.telemetry()
    let pill = confidenceHealthPill()

    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("\(confirmedIds.count) ingredient\(confirmedIds.count == 1 ? "" : "s") selected")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Confirm uncertain detections, then continue to recipe results.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        FLStatusPill(text: pill.text, kind: pill.kind)
      }

      HStack(spacing: AppTheme.Space.sm) {
        summaryCounter(
          label: "Auto", value: categorized.confirmed.count, icon: "checkmark.circle.fill")
        summaryCounter(
          label: "Confirm", value: categorized.needsConfirmation.count,
          icon: "questionmark.circle.fill")
        summaryCounter(label: "Maybe", value: categorized.possible.count, icon: "sparkles")
      }

      if telemetry.suggestionsShown > 0 {
        Text("Learning hit rate: \(Int((telemetry.hitRate * 100).rounded()))%")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }

      if scanProvenance != .realScan {
        FLStatusPill(
          text: scanProvenance == .bundledFixture ? "Bundled fixture fallback" : "Starter fallback",
          kind: .warning
        )
      }

      if let scanDiagnostics {
        Text(
          "Scan \(scanDiagnostics.elapsedMs)ms · auto \(scanDiagnostics.bucketCounts.auto) · confirm \(scanDiagnostics.bucketCounts.confirm) · maybe \(scanDiagnostics.bucketCounts.possible)"
        )
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      }

      if !categorized.needsConfirmation.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          HStack {
            Text("Confirmation progress")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("\(Int((confirmationCompletion * 100).rounded()))%")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
          }

          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(AppTheme.textSecondary.opacity(0.16))
              Capsule()
                .fill(AppTheme.accent)
                .frame(width: geo.size.width * confirmationCompletion)
            }
            .animation(reduceMotion ? nil : AppMotion.quick, value: confirmationCompletion)
          }
          .frame(height: 7)
        }
      }
    }
  }

  private func summaryCounter(label: String, value: Int, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
      Text("\(label): \(value)")
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }

  // MARK: - Nutrition Label Section

  private var nutritionLabelSection: some View {
    Group {
      if let parsed = nutritionLabelOutcome?.parsed {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          FLSectionHeader(
            "Packaged Nutrition Parsed",
            subtitle: "OCR detected label values for this scan.",
            icon: "doc.text.magnifyingglass"
          )

          HStack(spacing: AppTheme.Space.md) {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text("\(Int(parsed.caloriesPerServing.rounded())) kcal")
                .font(AppTheme.Typography.displayCaption)
              Text("Per serving")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if let servingSize = parsed.servingSize {
              VStack(alignment: .trailing, spacing: AppTheme.Space.xxxs) {
                Text(servingSize)
                  .font(AppTheme.Typography.bodyMedium)
                Text("Serving size")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
          }

          if let servings = parsed.servingsPerContainer {
            Text("Servings per container: \(String(format: "%.1f", servings))")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
          }

          Text("Source: \(parsed.source) · Confidence: \(parsed.confidence.rawValue.capitalized)")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.bottom, AppTheme.Space.lg)
      } else if nutritionLabelOutcome?.hadNutritionKeywords == true {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          FLSectionHeader(
            "Nutrition Label Detected",
            subtitle: "Couldn't confidently parse calories/serving.",
            icon: "exclamationmark.triangle.fill"
          )
          Text("Try a closer image of the nutrition panel if you want packaged values.")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.bottom, AppTheme.Space.lg)
      }
    }
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

  // MARK: - Confirmed Section (sage tint)

  private var confirmedSection: some View {
    Group {
      if !categorized.confirmed.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("AUTO-DETECTED")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(categorized.confirmed) { detection in
              OrganicIngredientChip(
                label: detection.label,
                isSelected: confirmedIds.contains(detection.ingredientId),
                chipStyle: .confirmed,
                confidence: detection.confidence,
                onInfo: {
                  if let ingredient = ingredient(for: detection.ingredientId) {
                    selectedIngredientForDetail = ingredient
                  }
                },
                action: {
                  toggleIngredient(detection.ingredientId)
                }
              )
            }
          }
        }
      }
    }
  }

  // MARK: - Needs Confirmation Section (oat tint, dashed border)

  private var needsConfirmationSection: some View {
    Group {
      if !categorized.needsConfirmation.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          Text("NEEDS CONFIRMATION")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          ForEach(categorized.needsConfirmation) { detection in
            confidenceRow(for: detection)
          }
        }
      }
    }
  }

  private func confidenceRow(for detection: Detection) -> some View {
    let options = candidateOptions(for: detection)
    let bucket = ConfidenceRouter.bucket(for: detection)

    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(detection.label)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text(
            "\(ConfidenceRouter.label(for: bucket)) · \(Int((detection.confidence * 100).rounded())) score"
          )
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          Text(ConfidenceRouter.explanation(for: detection))
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        Button {
          if let ingredient = ingredient(
            for: selectedIngredient(for: detection) ?? detection.ingredientId)
          {
            selectedIngredientForDetail = ingredient
          }
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
      }

      FlowLayout(spacing: AppTheme.Space.xs) {
        ForEach(options) { option in
          let isSelected = selectedIngredient(for: detection) == option.ingredientId

          Button {
            choose(option: option, for: detection)
          } label: {
            HStack(spacing: AppTheme.Space.xs) {
              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(AppTheme.Typography.label)
                .foregroundStyle(isSelected ? AppTheme.positive : AppTheme.textSecondary)
              Text(option.label)
                .font(AppTheme.Typography.label)
                .lineLimit(1)
              if let confidence = option.confidence {
                Text("\(Int((confidence * 100).rounded()))%")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .background(
              isSelected ? AppTheme.accent.opacity(0.18) : AppTheme.surfaceMuted
            )
            .clipShape(Capsule())
            .overlay(
              Capsule().stroke(
                isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.30),
                style: isSelected
                  ? StrokeStyle(lineWidth: 1) : StrokeStyle(lineWidth: 1, dash: [4, 3])
              )
            )
          }
          .buttonStyle(.plain)
        }
      }

      HStack {
        Button("Choose another") {
          showSheetMode = .correct(detection)
        }
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.accent)

        Spacer()

        Button("Not this item") {
          clearSelection(for: detection)
        }
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
      }

      Divider()
        .foregroundStyle(AppTheme.oat.opacity(0.20))
    }
  }

  // MARK: - Possible Section (stone tint, faded, smaller)

  private var possibleSection: some View {
    Group {
      if !categorized.possible.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("MAYBE")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(categorized.possible) { detection in
              OrganicIngredientChip(
                label: detection.label,
                isSelected: confirmedIds.contains(detection.ingredientId),
                chipStyle: .possible,
                confidence: detection.confidence,
                onInfo: {
                  if let ingredient = ingredient(for: detection.ingredientId) {
                    selectedIngredientForDetail = ingredient
                  }
                },
                action: {
                  toggleIngredient(detection.ingredientId)
                }
              )
            }
          }
        }
      }
    }
  }

  // MARK: - Bottom Bar

  private var bottomBar: some View {
    FLActionBar {
      if confirmedIds.isEmpty {
        Text("Pick at least one ingredient to continue to recipe matching.")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AppTheme.Space.page)
      }

      if unresolvedCount > 0 {
        Text(
          "\(unresolvedCount) uncertain item\(unresolvedCount == 1 ? "" : "s") remain. You can continue, but quality may improve after confirmation."
        )
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Space.page)
      }

      FLPrimaryButton(
        "Find Recipes (\(confirmedIds.count))",
        systemImage: "fork.knife",
        isEnabled: !confirmedIds.isEmpty
      ) {
        flushLearningTelemetry()
        navigateToResults = true
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.md)
    }
    .animation(reduceMotion ? nil : AppMotion.gentle, value: unresolvedCount)
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

    if let suggestion = deps.learningService.suggestedCorrection(for: detection.originalVisionLabel)
    {
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
      deps.learningService.recordCorrection(
        visionLabel: detection.originalVisionLabel,
        correctedIngredientId: option.ingredientId
      )
    }

    if let suggestion = deps.learningService.suggestedCorrection(for: detection.originalVisionLabel)
    {
      suggestedOutcomeByDetection[detection.id] = (option.ingredientId == suggestion)
    }
  }

  private func flushLearningTelemetry() {
    for (_, accepted) in suggestedOutcomeByDetection {
      deps.learningService.recordSuggestionOutcome(accepted: accepted)
    }
    suggestedOutcomeByDetection.removeAll()
  }

  private func candidateOptions(for detection: Detection) -> [DetectionAlternative] {
    var options: [DetectionAlternative] = []

    if let suggested = deps.learningService.suggestedCorrection(for: detection.originalVisionLabel)
    {
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
    let pairs: [(Int64, Ingredient)] = allIngredients.compactMap { ingredient in
      guard let id = ingredient.id else { return nil }
      return (id, ingredient)
    }
    let lookup = Dictionary(uniqueKeysWithValues: pairs)

    let seeded = ids.compactMap { lookup[$0] }
    return seeded.isEmpty ? allIngredients : seeded
  }
}

// MARK: - Add Chip Button Style

private struct FLAddChipButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}

// MARK: - Ingredient Chip

struct OrganicIngredientChip: View {
  let label: String
  let isSelected: Bool
  let chipStyle: ChipStyle
  let confidence: Float
  let onInfo: (() -> Void)?
  let action: () -> Void

  enum ChipStyle {
    case confirmed
    case possible

    var tint: Color {
      switch self {
      case .confirmed: return AppTheme.sage
      case .possible: return AppTheme.neutral
      }
    }

    var selectedTint: Color {
      switch self {
      case .confirmed: return AppTheme.sage
      case .possible: return AppTheme.accent
      }
    }
  }

  var body: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Button(action: action) {
        HStack(spacing: AppTheme.Space.xs) {
          Text(label)
            .font(
              chipStyle == .possible
                ? AppTheme.Typography.bodySmall : AppTheme.Typography.bodyMedium)
          if confidence < 0.65 {
            Text("\(Int(confidence * 100))%")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.chipVertical)
        .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
        .background(
          isSelected ? chipStyle.selectedTint.opacity(0.18) : chipStyle.tint.opacity(0.08),
          in: Capsule()
        )
        .overlay(
          Capsule().stroke(
            isSelected ? chipStyle.selectedTint.opacity(0.40) : chipStyle.tint.opacity(0.18),
            lineWidth: 1
          )
        )
        .opacity(chipStyle == .possible ? 0.85 : 1.0)
      }
      .buttonStyle(.plain)

      if let onInfo {
        Button(action: onInfo) {
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.textSecondary)
            .font(.system(size: 13))
        }
        .buttonStyle(.plain)
      }
    }
  }
}
