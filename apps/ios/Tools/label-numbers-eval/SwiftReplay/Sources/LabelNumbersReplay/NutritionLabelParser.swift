import Foundation

enum NutritionLabelConfidence: String, Sendable {
  case high
  case medium
  case low
}

struct NutritionLabelData: Sendable {
  let caloriesPerServing: Double
  let servingSize: String?
  let servingsPerContainer: Double?
  let confidence: NutritionLabelConfidence
  let source: String
}

struct NutritionLabelParseOutcome: Sendable {
  let parsed: NutritionLabelData?
  let hadNutritionKeywords: Bool
  let rawText: [String]
}

/// Extracts nutrition facts from OCR strings emitted by Vision text recognition.
enum NutritionLabelParser {
  static func parse(ocrText: [String]) -> NutritionLabelParseOutcome {
    let normalized = ocrText.map { normalize($0) }
    let fullText = normalized.joined(separator: " ")
    let lowered = fullText.lowercased()

    let hadNutritionKeywords =
      lowered.contains("calories")
      || lowered.contains("serving size")
      || lowered.contains("servings per container")

    let calories = extractCalories(from: fullText)
    let servingSize = extractServingSize(from: fullText)
    let servingsPerContainer = extractServingsPerContainer(from: fullText)

    guard let calories else {
      return NutritionLabelParseOutcome(
        parsed: nil,
        hadNutritionKeywords: hadNutritionKeywords,
        rawText: ocrText
      )
    }

    let confidence: NutritionLabelConfidence
    if servingSize != nil, servingsPerContainer != nil {
      confidence = .high
    } else if servingSize != nil || servingsPerContainer != nil {
      confidence = .medium
    } else {
      confidence = .low
    }

    return NutritionLabelParseOutcome(
      parsed: NutritionLabelData(
        caloriesPerServing: calories,
        servingSize: servingSize,
        servingsPerContainer: servingsPerContainer,
        confidence: confidence,
        source: "Nutrition Label OCR"
      ),
      hadNutritionKeywords: hadNutritionKeywords,
      rawText: ocrText
    )
  }

  private static func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "•", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func extractCalories(from text: String) -> Double? {
    // Common Nutrition Facts patterns:
    // "Calories 120", "Calories: 120", "Calories 120 kcal".
    let patterns = [
      #"(?i)\bcalories?\s*[:\-]?\s*(\d{1,4}(?:\.\d{1,2})?)\b"#,
      #"(?i)\benergy\s*[:\-]?\s*(\d{1,4}(?:\.\d{1,2})?)\s*kcal\b"#,
    ]
    for pattern in patterns {
      if let value = firstNumericCapture(pattern: pattern, in: text) {
        return value
      }
    }
    return nil
  }

  private static func extractServingSize(from text: String) -> String? {
    let patterns = [
      #"(?i)\bserving\s*size\s*[:\-]?\s*([A-Za-z0-9\.\,\(\)\/\-\s]{2,40})"#,
      #"(?i)\bserv\.\s*size\s*[:\-]?\s*([A-Za-z0-9\.\,\(\)\/\-\s]{2,40})"#,
    ]
    for pattern in patterns {
      guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: text,
          range: NSRange(text.startIndex..<text.endIndex, in: text)
        ),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: text)
      else { continue }

      let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      let cleaned =
        raw
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ":;,. "))

      if !cleaned.isEmpty {
        return cleaned
      }
    }
    return nil
  }

  private static func extractServingsPerContainer(from text: String) -> Double? {
    let patterns = [
      #"(?i)\bservings?\s*per\s*container\s*[:\-]?\s*(?:about\s+)?(\d{1,3}(?:\.\d{1,2})?)\b"#,
      #"(?i)\bservings?\s*[:\-]?\s*(\d{1,3}(?:\.\d{1,2})?)\b"#,
    ]
    for pattern in patterns {
      if let value = firstNumericCapture(pattern: pattern, in: text) {
        return value
      }
    }
    return nil
  }

  private static func firstNumericCapture(pattern: String, in text: String) -> Double? {
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
      ),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: text)
    else { return nil }

    return Double(text[range])
  }
}
