import SwiftUI

/// Review detected ingredients: confirm, remove, correct, or add manually.
/// Then proceed to recipe recommendations.
struct IngredientReviewView: View {
  @EnvironmentObject var deps: AppDependencies
  @State var detections: [Detection]

  @State private var confirmedIds: Set<Int64> = []
  @State private var showSheetMode: IngredientSheetMode?
  @State private var navigateToResults = false
  @State private var allIngredients: [Ingredient] = []
  @State private var selectedIngredientForDetail: Ingredient?

  @State private var selectedIngredientForDetection: [UUID: Int64] = [:]
  @State private var suggestedOutcomeByDetection: [UUID: Bool] = [:]
  @State private var didInitialize = false

  private enum IngredientSheetMode: Identifiable {
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
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          headerSection
          confirmedSection
          needsConfirmationSection
          possibleSection
        }
        .padding()
      }

      bottomBar
    }
    .navigationTitle("Your Ingredients")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showSheetMode = .addManual
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(item: $showSheetMode) { mode in
      IngredientSearchSheet(
        allIngredients: allIngredients,
        onSelect: { ingredient in
          switch mode {
          case .addManual:
            addManualIngredient(ingredient)
          case .correct(let detection):
            applyManualCorrection(ingredient: ingredient, detection: detection)
          }
        }
      )
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

  private func categorizeDetections() {
    let results = categorized

    // Auto-confirm high-confidence detections
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
    ingredient(for: id)?.name.replacingOccurrences(of: "_", with: " ").capitalized
      ?? IngredientLexicon.displayName(for: id)
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(confirmedIds.count) ingredient\(confirmedIds.count == 1 ? "" : "s") selected")
        .font(.headline)
      Text("Tap to add or remove items")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      let telemetry = deps.learningService.telemetry()
      if telemetry.suggestionsShown > 0 {
        Text("Learning hit rate: \(Int((telemetry.hitRate * 100).rounded()))%")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Sections

  private var confirmedSection: some View {
    Group {
      if !categorized.confirmed.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Label("Auto-detected", systemImage: "checkmark.circle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.green)

          FlowLayout(spacing: 8) {
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

  private var needsConfirmationSection: some View {
    Group {
      if !categorized.needsConfirmation.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Label("Please confirm", systemImage: "questionmark.circle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.orange)

          ForEach(categorized.needsConfirmation) { detection in
            confidenceCard(for: detection)
          }
        }
      }
    }
  }

  private func confidenceCard(for detection: Detection) -> some View {
    let options = candidateOptions(for: detection)

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(detection.label)
            .font(.headline)
          Text("Detected with \(Int((detection.confidence * 100).rounded()))% confidence")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        }
        .buttonStyle(.plain)
      }

      FlowLayout(spacing: 8) {
        ForEach(options) { option in
          Button {
            choose(option: option, for: detection)
          } label: {
            Text(option.label)
              .font(.subheadline)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                selectedIngredient(for: detection) == option.ingredientId
                  ? .yellow.opacity(0.25) : .gray.opacity(0.12)
              )
              .clipShape(Capsule())
              .overlay(
                Capsule().stroke(
                  selectedIngredient(for: detection) == option.ingredientId ? .yellow : .clear,
                  lineWidth: 1.5
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
        .font(.caption)

        Spacer()

        Button("Not this item") {
          clearSelection(for: detection)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(.orange.opacity(0.2), lineWidth: 1)
    )
  }

  private var possibleSection: some View {
    Group {
      if !categorized.possible.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Label("Maybe?", systemImage: "sparkles")
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)

          FlowLayout(spacing: 8) {
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

  // MARK: - Bottom Bar

  private var bottomBar: some View {
    VStack(spacing: 0) {
      Divider()
      Button {
        flushLearningTelemetry()
        navigateToResults = true
      } label: {
        Text("Find Recipes (\(confirmedIds.count) ingredients)")
          .frame(maxWidth: .infinity)
          .padding()
          .background(confirmedIds.isEmpty ? .gray.opacity(0.3) : .yellow)
          .foregroundStyle(confirmedIds.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.black))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .font(.headline)
      }
      .disabled(confirmedIds.isEmpty)
      .padding()
    }
    .background(.ultraThinMaterial)
  }

  // MARK: - Actions

  private func toggleIngredient(_ id: Int64) {
    if confirmedIds.contains(id) {
      confirmedIds.remove(id)
    } else {
      confirmedIds.insert(id)
    }
  }

  private func addManualIngredient(_ ingredient: Ingredient) {
    guard let id = ingredient.id else { return }

    let detection = Detection(
      ingredientId: id,
      label: ingredient.name.replacingOccurrences(of: "_", with: " ").capitalized,
      confidence: 1.0,
      source: .manual,
      originalVisionLabel: ingredient.name,
      alternatives: []
    )
    detections.append(detection)
    confirmedIds.insert(id)
  }

  private func applyManualCorrection(ingredient: Ingredient, detection: Detection) {
    guard let id = ingredient.id else { return }
    choose(
      option: DetectionAlternative(
        ingredientId: id,
        label: ingredient.name.replacingOccurrences(of: "_", with: " ").capitalized,
        confidence: nil
      ),
      for: detection
    )
  }

  private func selectedIngredient(for detection: Detection) -> Int64? {
    selectedIngredientForDetection[detection.id]
  }

  private func clearSelection(for detection: Detection) {
    if let previous = selectedIngredient(for: detection) {
      confirmedIds.remove(previous)
    }
    selectedIngredientForDetection.removeValue(forKey: detection.id)

    if let suggestion = deps.learningService.suggestedCorrection(for: detection.originalVisionLabel)
    {
      suggestedOutcomeByDetection[detection.id] = (suggestion == detection.ingredientId)
    }
  }

  private func choose(option: DetectionAlternative, for detection: Detection) {
    if let previous = selectedIngredient(for: detection) {
      confirmedIds.remove(previous)
    }

    selectedIngredientForDetection[detection.id] = option.ingredientId
    confirmedIds.insert(option.ingredientId)

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
    var ids: [Int64] = []

    if let suggested = deps.learningService.suggestedCorrection(for: detection.originalVisionLabel)
    {
      ids.append(suggested)
    }

    ids.append(detection.ingredientId)

    for alternative in detection.alternatives {
      ids.append(alternative.ingredientId)
    }

    var unique: [Int64] = []
    for id in ids where !unique.contains(id) {
      unique.append(id)
      if unique.count >= 4 { break }
    }

    return unique.map {
      DetectionAlternative(
        ingredientId: $0,
        label: displayName(for: $0),
        confidence: nil
      )
    }
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
    HStack(spacing: 6) {
      Button(action: action) {
        HStack(spacing: 4) {
          Text(label)
            .font(.subheadline)
          if confidence < 0.65 {
            Text("\(Int(confidence * 100))%")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? .yellow.opacity(0.2) : .gray.opacity(0.1))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .stroke(isSelected ? .yellow : .clear, lineWidth: 1.5)
        )
      }
      .buttonStyle(.plain)

      if let onInfo {
        Button(action: onInfo) {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
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

// MARK: - Ingredient Search Sheet

struct IngredientSearchSheet: View {
  let allIngredients: [Ingredient]
  let onSelect: (Ingredient) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var filtered: [Ingredient] {
    if searchText.isEmpty { return allIngredients }
    let query = searchText.lowercased()
    return allIngredients.filter {
      $0.name.lowercased().contains(query)
    }
  }

  var body: some View {
    NavigationStack {
      List(filtered, id: \.id) { ingredient in
        Button {
          onSelect(ingredient)
          dismiss()
        } label: {
          HStack {
            Text(ingredient.name.replacingOccurrences(of: "_", with: " ").capitalized)
            Spacer()
            Text("\(Int(ingredient.calories)) kcal/100g")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .foregroundStyle(.primary)
      }
      .searchable(text: $searchText, prompt: "Search ingredients")
      .navigationTitle("Select Ingredient")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}
