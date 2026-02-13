import SwiftUI

/// Review detected ingredients: confirm, remove, correct, or add manually.
/// Then proceed to recipe recommendations.
struct IngredientReviewView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State var detections: [Detection]
  let nutritionLabelOutcome: NutritionLabelParseOutcome?

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
    nutritionLabelOutcome: NutritionLabelParseOutcome? = nil
  ) {
    self._detections = State(initialValue: detections)
    self.nutritionLabelOutcome = nutritionLabelOutcome
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
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          summarySection
          nutritionLabelSection
          bulkActionSection
          confirmedSection
          needsConfirmationSection
          possibleSection
        }
        .padding(.horizontal, AppTheme.Space.md)
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
          Label("Add", systemImage: "plus")
            .labelStyle(.iconOnly)
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

    // Auto-confirm high-confidence detections.
    for detection in results.confirmed {
      confirmedIds.insert(detection.ingredientId)
    }

    // For medium-confidence detections, preselect learned suggestion when available.
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

  // MARK: - Sections

  private var summarySection: some View {
    let telemetry = deps.learningService.telemetry()
    let pill = confidenceHealthPill()

    return FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text("\(confirmedIds.count) ingredient\(confirmedIds.count == 1 ? "" : "s") selected")
              .font(.title3.bold())
              .foregroundStyle(AppTheme.textPrimary)
            Text("Confirm uncertain detections, then continue to recipe results.")
              .font(.subheadline)
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
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }

        if !categorized.needsConfirmation.isEmpty {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
            HStack {
              Text("Confirmation progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
              Spacer()
              Text("\(Int((confirmationCompletion * 100).rounded()))%")
                .font(.caption.weight(.semibold))
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
  }

  private func summaryCounter(label: String, value: Int, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
      Text("\(label): \(value)")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surface, in: Capsule())
  }

  private var nutritionLabelSection: some View {
    Group {
      if let parsed = nutritionLabelOutcome?.parsed {
        FLCard(tone: .normal) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader(
              "Packaged Nutrition Parsed",
              subtitle: "OCR detected label values for this scan.",
              icon: "doc.text.magnifyingglass"
            )

            HStack(spacing: AppTheme.Space.md) {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(parsed.caloriesPerServing.rounded())) kcal")
                  .font(.headline)
                Text("Per serving")
                  .font(.caption)
                  .foregroundStyle(AppTheme.textSecondary)
              }
              Spacer()
              if let servingSize = parsed.servingSize {
                VStack(alignment: .trailing, spacing: 2) {
                  Text(servingSize)
                    .font(.subheadline)
                  Text("Serving size")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                }
              }
            }

            if let servings = parsed.servingsPerContainer {
              Text("Servings per container: \(String(format: "%.1f", servings))")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Text("Source: \(parsed.source) · Confidence: \(parsed.confidence.rawValue.capitalized)")
              .font(.caption2)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      } else if nutritionLabelOutcome?.hadNutritionKeywords == true {
        FLCard(tone: .warning) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader(
              "Nutrition Label Detected",
              subtitle: "Couldn’t confidently parse calories/serving.",
              icon: "exclamationmark.triangle.fill"
            )
            Text("Try a closer image of the nutrition panel if you want packaged values.")
              .font(.caption)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
    }
  }

  private var bulkActionSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Quick Actions", subtitle: "Speed up confirmation", icon: "slider.horizontal.3")

        HStack(spacing: AppTheme.Space.sm) {
          FLSecondaryButton("Select Auto", systemImage: "checkmark.seal.fill") {
            selectAllAutoDetected()
          }

          FLSecondaryButton("Clear Uncertain", systemImage: "xmark.circle") {
            clearUncertainSelections()
          }
        }

        FLSecondaryButton("Open Ingredient Picker", systemImage: "plus.circle") {
          showSheetMode = .addManual
        }
      }
    }
  }

  private var confirmedSection: some View {
    Group {
      if !categorized.confirmed.isEmpty {
        FLCard {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader(
              "Auto-detected", subtitle: "High-confidence items", icon: "checkmark.circle.fill")

            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(categorized.confirmed) { detection in
                IngredientChip(
                  label: detection.label,
                  isSelected: confirmedIds.contains(detection.ingredientId),
                  confidence: detection.confidence,
                  onInfo: {
                    if let ingredient = ingredient(for: detection.ingredientId) {
                      selectedIngredientForDetail = ingredient
                    }
                  }
                ) {
                  toggleIngredient(detection.ingredientId)
                }
              }
            }
          }
        }
      }
    }
  }

  private var needsConfirmationSection: some View {
    Group {
      if !categorized.needsConfirmation.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          FLSectionHeader(
            "Needs Confirmation",
            subtitle: "Medium-confidence predictions requiring your decision",
            icon: "questionmark.circle.fill"
          )

          ForEach(categorized.needsConfirmation) { detection in
            confidenceCard(for: detection)
          }
        }
      }
    }
  }

  private func confidenceCard(for detection: Detection) -> some View {
    let options = candidateOptions(for: detection)

    return FLCard(tone: .warning) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(detection.label)
              .font(.headline)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Detected at \(Int((detection.confidence * 100).rounded()))% confidence")
              .font(.caption)
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
                  .font(.caption)
                  .foregroundStyle(isSelected ? AppTheme.positive : AppTheme.textSecondary)
                Text(option.label)
                  .font(.subheadline.weight(.semibold))
                  .lineLimit(1)
                if let confidence = option.confidence {
                  Text("\(Int((confidence * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                }
              }
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.xs)
              .background(
                isSelected
                  ? AppTheme.accent.opacity(0.3) : AppTheme.surface
              )
              .clipShape(Capsule())
              .overlay(
                Capsule().stroke(
                  isSelected
                    ? AppTheme.accent : AppTheme.textSecondary.opacity(0.15),
                  lineWidth: 1
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
          .font(.caption.weight(.semibold))
          .foregroundStyle(AppTheme.textPrimary)

          Spacer()

          Button("Not this item") {
            clearSelection(for: detection)
          }
          .font(.caption)
          .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  private var possibleSection: some View {
    Group {
      if !categorized.possible.isEmpty {
        FLCard {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            FLSectionHeader("Maybe", subtitle: "Lower-confidence suggestions", icon: "sparkles")

            FlowLayout(spacing: AppTheme.Space.xs) {
              ForEach(categorized.possible) { detection in
                IngredientChip(
                  label: detection.label,
                  isSelected: confirmedIds.contains(detection.ingredientId),
                  confidence: detection.confidence,
                  onInfo: {
                    if let ingredient = ingredient(for: detection.ingredientId) {
                      selectedIngredientForDetail = ingredient
                    }
                  }
                ) {
                  toggleIngredient(detection.ingredientId)
                }
              }
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
          .font(.caption)
          .foregroundStyle(AppTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AppTheme.Space.md)
      }

      if unresolvedCount > 0 {
        Text(
          "\(unresolvedCount) uncertain item\(unresolvedCount == 1 ? "" : "s") remain. You can continue, but quality may improve after confirmation."
        )
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Space.md)
      }

      FLPrimaryButton(
        "Find Recipes (\(confirmedIds.count))",
        systemImage: "fork.knife",
        isEnabled: !confirmedIds.isEmpty
      ) {
        flushLearningTelemetry()
        navigateToResults = true
      }
      .padding(.horizontal, AppTheme.Space.md)
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

// MARK: - Ingredient Chip

struct IngredientChip: View {
  let label: String
  let isSelected: Bool
  let confidence: Float
  let onInfo: (() -> Void)?
  let action: () -> Void

  var body: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Button(action: action) {
        HStack(spacing: AppTheme.Space.xs) {
          Text(label)
            .font(.subheadline)
          if confidence < 0.65 {
            Text("\(Int(confidence * 100))%")
              .font(.caption2)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.xs)
        .background(isSelected ? AppTheme.accent.opacity(0.26) : AppTheme.surface)
        .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .stroke(
              isSelected ? AppTheme.accent : AppTheme.textSecondary.opacity(0.16), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      if let onInfo {
        Button(action: onInfo) {
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Flow Layout (wrapping tags)

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = arrange(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(proposal: proposal, subviews: subviews)
    for (index, position) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        proposal: ProposedViewSize(result.sizes[index])
      )
    }
  }

  private struct ArrangeResult {
    var size: CGSize
    var positions: [CGPoint]
    var sizes: [CGSize]
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var sizes: [CGSize] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      sizes.append(size)

      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }

      positions.append(CGPoint(x: x, y: y))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
    }

    return ArrangeResult(
      size: CGSize(width: maxWidth, height: y + rowHeight),
      positions: positions,
      sizes: sizes
    )
  }
}
