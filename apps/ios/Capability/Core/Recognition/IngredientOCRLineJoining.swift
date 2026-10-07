import CoreGraphics
import Foundation

/// Joins packaging text before catalog fallback can assign an identity to a partial line.
enum IngredientOCRLineJoining {
  struct Line: Sendable, Equatable {
    let text: String
    let boundingBox: CGRect
    var joinedParts: [String] = []
  }

  static func joinAdjacent(_ observations: [Line]) -> [Line] {
    let lines = observations.sorted(by: readingOrder)
    var consumed = Set<Int>()
    var result: [Line] = []
    for i in lines.indices where !consumed.contains(i) {
      let first = lines[i]
      guard IngredientLexicon.resolveFromTextDetailed(first.text) == nil,
        let j = lines.indices.first(where: {
          startsLowerRow(first.boundingBox, above: lines[$0].boundingBox)
            && horizontallyAligned(first.boundingBox, lines[$0].boundingBox)
        }),
        !consumed.contains(j)
      else { continue }
      let second = lines[j]
      guard adjacent(first.boundingBox, above: second.boundingBox),
        IngredientLexicon.resolveFromTextDetailed(second.text) == nil
      else { continue }
      let phrase = first.text + " " + second.text
      guard IngredientLexicon.resolveFromTextDetailed(phrase) != nil else { continue }
      result.append(
        Line(
          text: phrase, boundingBox: first.boundingBox.union(second.boundingBox),
          joinedParts: [first.text, second.text]))
      consumed.insert(i)
      consumed.insert(j)
    }
    // Only original observations are considered for pairs; joined lines never form chains.
    result += lines.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
    return result.sorted(by: readingOrder)
  }

  private static func readingOrder(_ lhs: Line, _ rhs: Line) -> Bool {
    let a = lhs.boundingBox
    let b = rhs.boundingBox
    // Vision's origin is bottom-left, so a larger minY is higher on the page.
    if a.minY != b.minY { return a.minY > b.minY }
    if a.minX != b.minX { return a.minX < b.minX }
    if a.width != b.width { return a.width < b.width }
    if a.height != b.height { return a.height < b.height }
    return lhs.text < rhs.text
  }

  private static func horizontallyAligned(_ upper: CGRect, _ lower: CGRect) -> Bool {
    guard upper.width > 0, lower.width > 0, upper.height > 0, lower.height > 0 else { return false }
    let overlap = max(0, min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX))
    return overlap / min(upper.width, lower.width) >= 0.7
  }

  private static func startsLowerRow(_ upper: CGRect, above lower: CGRect) -> Bool {
    let height = max(upper.height, lower.height)
    // Overlap beyond the adjacency allowance is the same row, not an intervening row.
    return lower.minY < upper.minY && upper.minY - lower.maxY >= -0.25 * height
  }

  private static func adjacent(_ upper: CGRect, above lower: CGRect) -> Bool {
    let height = max(upper.height, lower.height)
    let gap = upper.minY - lower.maxY
    // On the five bundled demo photos, joins used at least 70% horizontal overlap and
    // a gap from -25% to 100% of the taller line's height, in Vision's bottom-left coordinates.
    // These limits have not been tuned beyond those photos.
    return gap >= -0.25 * height && gap <= height
  }
}

/// Prevents a complete curated phrase and its catalog-resolved parts from becoming separate foods.
enum IngredientOCRMatchAggregation {
  struct Match {
    let ingredientId: Int64
    let confidence: Float
    let originalText: String
    let matchedToken: String
    let kind: OCRMatchKind
    let boundingBox: CGRect
    let cropID: String
    let captureIndex: Int
    let isCatalogFallback: Bool
    let joinedParts: [String]
  }

  static func suppressJoinedParts(_ matches: [Match]) -> [Match] {
    var partsByCapture: [Int: Set<String>] = [:]
    for match in matches where !match.isCatalogFallback && !match.joinedParts.isEmpty {
      partsByCapture[match.captureIndex, default: []].formUnion(match.joinedParts.map(normalize))
    }
    return matches.filter { match in
      !match.isCatalogFallback
        || !(partsByCapture[match.captureIndex]?.contains(normalize(match.originalText)) ?? false)
    }
  }

  private static func normalize(_ text: String) -> String {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
}
