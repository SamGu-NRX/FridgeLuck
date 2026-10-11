import Foundation

/// Deterministic rendered document: no timestamps, always '.' decimal separator,
/// LF newlines, rows in intake order.
enum RecipeExportRendering {
  static func renderedText(of document: RecipeExportPrepared) -> String {
    var lines: [String] = []
    lines.append("\(document.recipeName) — ingredient amounts")
    lines.append(
      "Servings: \(RecipeExportNumberText.amount(document.exportedServings))"
      + " (recipe base: \(document.originalServings))"
    )
    lines.append("")
    for (index, row) in document.rows.enumerated() {
      let requirement = row.isRequired ? "Required" : "Optional"
      lines.append("\(index + 1). \(row.name) — \(row.quantityText) — \(requirement)")
      if let substitutedName = row.substitutedName {
        let ratio = RecipeExportNumberText.amount(row.substitutionRatio ?? 1)
        lines.append("   swap: \(substitutedName) (ratio \(ratio))")
      }
      if let note = row.replacementNote, !note.isEmpty {
        lines.append("   note: \(note)")
      }
    }
    lines.append("")
    if let url = document.sourceURL {
      lines.append("Source: \(url.absoluteString)")
    }
    lines.append("Amount list only — cooking instructions are not included.")
    return lines.joined(separator: "\n")
  }
}

enum RecipeExportNumberText {
  /// One fractional digit at most, '.' separator, trailing '.0' trimmed
  /// (250 → '250', 66.65 → '66.7', 0.5 → '0.5'). Integer math on tenth-units
  /// so the output never depends on the process locale. Non-finite input is a
  /// trap guard only — validation rejects those cases before rendering.
  static func amount(_ value: Double) -> String {
    let tenths = (value * 10).rounded()
    guard tenths.isFinite, tenths.magnitude < 9e15 else { return "unspecified" }
    let total = Int(tenths)
    if total % 10 == 0 { return String(total / 10) }
    let sign = total < 0 ? "-" : ""
    let magnitude = abs(total)
    return "\(sign)\(magnitude / 10).\(magnitude % 10)"
  }
}

enum RecipeExportNaming {
  static func defaultName(recipeName: String, exportedServings: Double) -> String {
    let slug = asciiSlug(recipeName)
    let base = slug.isEmpty ? "recipe" : slug
    return "\(base)-amounts-\(servingsToken(exportedServings))-servings.txt"
  }

  /// Lowercase, keep only ASCII [a-z0-9] runs, join runs with a single '-',
  /// collapse repeats, trim '-'. Diacritics are stripped after canonical
  /// decomposition (è → e), never transliterated; 'Crème brûlée' → 'creme-brulee'.
  private static func asciiSlug(_ name: String) -> String {
    let lowered = name.lowercased().decomposedStringWithCanonicalMapping
    var runs: [String] = []
    var current = ""
    for scalar in lowered.unicodeScalars {
      if isASCIILowercaseOrDigit(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        runs.append(current)
        current = ""
      }
    }
    if !current.isEmpty { runs.append(current) }
    return runs.joined(separator: "-")
  }

  /// Fractional servings keep one decimal with '.' → 'p' (2.5 → '2p5', 4 → '4').
  private static func servingsToken(_ exportedServings: Double) -> String {
    RecipeExportNumberText.amount(exportedServings).replacingOccurrences(of: ".", with: "p")
  }

  private static func isASCIILowercaseOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x61...0x7A, 0x30...0x39: return true
    default: return false
    }
  }
}
