import CoreGraphics

/// Joins packaging text before catalog fallback can assign an identity to a partial line.
enum IngredientOCRLineJoining {
  struct Line: Sendable, Equatable {
    let text: String
    let boundingBox: CGRect
  }

  static func joinAdjacent(_ lines: [Line]) -> [Line] {
    var consumed = Set<Int>()
    var joined: [Line] = []
    for i in lines.indices where !consumed.contains(i) {
      let first = lines[i]
      guard IngredientLexicon.resolveFromTextDetailed(first.text) == nil else { continue }
      for j in lines.indices where i != j && !consumed.contains(j) {
        let second = lines[j]
        guard aligned(first.boundingBox, above: second.boundingBox),
          IngredientLexicon.resolveFromTextDetailed(second.text) == nil
        else { continue }
        let phrase = first.text + " " + second.text
        guard IngredientLexicon.resolveFromTextDetailed(phrase) != nil else { continue }
        joined.append(Line(text: phrase, boundingBox: first.boundingBox.union(second.boundingBox)))
        consumed.insert(i)
        consumed.insert(j)
        break
      }
    }
    // Only original observations are considered for pairs; joined lines never form chains.
    return lines.enumerated().filter { !consumed.contains($0.offset) }.map(\.element) + joined
  }

  private static func aligned(_ upper: CGRect, above lower: CGRect) -> Bool {
    guard upper.width > 0, lower.width > 0, upper.height > 0, lower.height > 0,
      upper.minY > lower.minY
    else { return false }
    let overlap = max(0, min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX))
    let height = max(upper.height, lower.height)
    let gap = upper.minY - lower.maxY
    // BRIEF-8's measured rule uses Vision's bottom-left coordinates: overlap at least
    // 70% of the narrower line, with a gap from -25% to 100% of the taller line's height.
    return overlap / min(upper.width, lower.width) >= 0.7
      && gap >= -0.25 * height && gap <= height
  }
}
