import SwiftUI

/// Review detected ingredients: confirm, remove, correct, or add manually.
/// Then proceed to recipe recommendations.
struct IngredientReviewView: View {
  @EnvironmentObject var deps: AppDependencies
  @State var detections: [Detection]

  @State private var confirmedIds: Set<Int64> = []
  @State private var showIngredientSearch = false
  @State private var navigateToResults = false
  @State private var allIngredients: [Ingredient] = []

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
          showIngredientSearch = true
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(isPresented: $showIngredientSearch) {
      IngredientSearchSheet(
        allIngredients: allIngredients,
        onSelect: { ingredient in
          addManualIngredient(ingredient)
        }
      )
    }
    .navigationDestination(isPresented: $navigateToResults) {
      RecipeResultsView(ingredientIds: confirmedIds)
    }
    .onAppear {
      categorizeDetections()
      loadAllIngredients()
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
  }

  private func loadAllIngredients() {
    allIngredients = (try? deps.ingredientRepository.fetchAll()) ?? []
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(confirmedIds.count) ingredient\(confirmedIds.count == 1 ? "" : "s") selected")
        .font(.headline)
      Text("Tap to add or remove items")
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
                confidence: detection.confidence
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
        VStack(alignment: .leading, spacing: 8) {
          Label("Please confirm", systemImage: "questionmark.circle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.orange)

          FlowLayout(spacing: 8) {
            ForEach(categorized.needsConfirmation) { detection in
              IngredientChip(
                label: detection.label,
                isSelected: confirmedIds.contains(detection.ingredientId),
                confidence: detection.confidence
              ) {
                toggleIngredient(detection.ingredientId)
              }
            }
          }
        }
      }
    }
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
                confidence: detection.confidence
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

    // Add as a manual detection
    let detection = Detection(
      ingredientId: id,
      label: ingredient.name.replacingOccurrences(of: "_", with: " ").capitalized,
      confidence: 1.0,
      source: .manual,
      originalVisionLabel: ingredient.name
    )
    detections.append(detection)
    confirmedIds.insert(id)
  }
}

// MARK: - Ingredient Chip

struct IngredientChip: View {
  let label: String
  let isSelected: Bool
  let confidence: Float
  let action: () -> Void

  var body: some View {
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
      .navigationTitle("Add Ingredient")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}
