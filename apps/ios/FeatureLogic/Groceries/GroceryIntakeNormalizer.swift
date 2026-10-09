import Foundation

/// Turns recognition output into reviewable grocery drafts.
///
/// The normalizer owns two honest-amount rules that the review UI and the intake service
/// both rely on:
/// - A price, tax or total never becomes grams. Weight comes from explicit unit text,
///   counts become grams only through the caller's known unit-mass estimator, and
///   everything else stays unknown until the user sets it.
/// - Count evidence multiplies a known unit mass (2 eggs ≈ 100 g); without one the item
///   enters review with an unknown amount rather than a made-up total.
public enum GroceryIntakeNormalizer {
  // MARK: - Receipt mode (ordered OCR lines)

  /// Parses ordered receipt OCR lines into drafts. `resolve` maps a line's text to an
  /// ingredient with its identity confidence (the app glue distinguishes exact from fuzzy
  /// lexicon matches); `alternativesFor` supplies correction candidates; `estimateGrams`
  /// returns the known unit mass for an ingredient or nil when the catalog has no entry.
  public static func draftItems(
    fromReceiptLines lines: [String],
    resolve: (String) -> (id: Int64, confidence: Double)?,
    alternativesFor: (String) -> [GroceryAlternative],
    estimateUnitGrams: (Int64) -> Double?,
    inferLocation: (Int64) -> GroceryStorageLocation
  ) -> [GroceryDraftItem] {
    let parsed = GroceryReceiptParser.parse(lines)

    var drafts: [GroceryDraftItem] = []
    for line in parsed where line.classification.isItem {
      let identity = resolve(line.rawText)
      let alternatives = alternativesFor(line.rawText)

      var amount = line.amount
      var grams = amount?.grams
      // A count without explicit weight becomes grams only with a known unit mass.
      if grams == nil, let identity, let count = amount?.count, count > 0 {
        if let unitMass = estimateUnitGrams(identity.id) {
          grams = unitMass * Double(count)
        }
      }
      // Amount text was unusable (price-only or unresolved count): leave unknown.
      if grams == nil { amount = nil }

      drafts.append(
        GroceryDraftItem(
          ingredientId: identity?.id,
          title: displayTitle(line.rawText),
          confidence: identity?.confidence ?? 0.5,
          amountGrams: grams,
          countEvidence: line.amount?.count,
          provenance: grams.map { _ in amount?.provenance ?? .estimate },
          rawDescription: line.rawText,
          evidenceSummary: line.amount?.rawText,
          location: identity.map { inferLocation($0.id) } ?? .unknown,
          source: .ocr,
          alternatives: alternatives
        ))
    }
    return drafts
  }

  // MARK: - Photo mode (vision detections + packaging OCR)

  /// Builds drafts from photo-mode detections. Each detection is one recognized unit: the
  /// amount is the unit-mass estimate unless the photo's OCR carries a packaging net weight
  /// and there is a single product in frame, in which case that measured weight wins.
  public static func draftItems(
    fromDetections detections: [GroceryDetectionInput],
    ocrText: [String],
    estimateGramsForName: (String) -> Double?,
    inferLocation: (Int64) -> GroceryStorageLocation
  ) -> [GroceryDraftItem] {
    let packaging = ocrText.isEmpty ? nil : GroceryReceiptParser.packagingAmount(in: ocrText)
    let measuredApplies = detections.count == 1 && detections.first?.ingredientId != nil

    return detections.map { detection in
      var grams: Double?
      if detection.ingredientId != nil, let unitMass = estimateGramsForName(detection.label) {
        grams = unitMass * Double(max(1, detection.count))
      }
      var provenance: GroceryAmountProvenance? = grams.map { _ in .estimate }
      var evidence: String? = detection.count > 1 ? "×\(detection.count)" : nil

      if measuredApplies, let packaging = packaging {
        grams = packaging.grams
        provenance = .measured
        evidence = packaging.rawText
      }

      return GroceryDraftItem(
        ingredientId: detection.ingredientId,
        title: detection.label,
        confidence: Double(detection.confidence),
        amountGrams: grams,
        countEvidence: detection.count,
        provenance: provenance,
        rawDescription: detection.label,
        evidenceSummary: evidence,
        location: detection.ingredientId.map(inferLocation) ?? .unknown,
        source: .vision,
        alternatives: detection.alternatives
      )
    }
  }

  // MARK: - Session references

  /// Parses a value the user typed into the review. "500g", "0.5 kg", "12 oz" are explicit
  /// weights the user read off the packaging (`.measured`); a plain "500" is their own
  /// setting (`.entered`). Returns nil for anything unparsable — never a guess.
  public static func parseUserAmount(_ text: String)
    -> (grams: Double, provenance: GroceryAmountProvenance)?
  {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let weight = GroceryReceiptParser.parseExplicitWeight(in: trimmed) {
      return (weight.grams, .measured)
    }

    let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0,
      value <= GroceryReceiptParser.maxPlausibleGrams
    else { return nil }
    return ((value * 10).rounded() / 10, .entered)
  }

  /// A stable per-review reference for the intake write. Created once when review opens and
  /// reused across retries, so a retry after a failed commit re-runs the batch atomically
  /// and a double-fire commits once.
  public static func newSessionRef() -> String {
    "grocery_update_\(UUID().uuidString)"
  }

  // MARK: - Helpers

  /// Strips amount and price tokens from a raw line for display.
  public static func displayTitle(_ rawText: String) -> String {
    var text = rawText
    if let weight = GroceryReceiptParser.parseExplicitWeight(in: text),
      let range = text.range(of: weight.rawText)
    {
      text = text.replacingCharacters(in: range, with: " ")
    }
    let cleaned =
      text
      .replacingOccurrences(of: #"\$\s*\d+(?:[.,]\d{1,2})?"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\d+(?:[.,]\d{1,2})?\s*[€£]"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    let collapsed = cleaned
      .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"@\s*$"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    return collapsed.isEmpty ? rawText : collapsed
  }
}

/// Detection input for photo-mode drafts: the identity pipeline's result for one recognized
/// unit, in Foundation-only shape (the app maps its `Detection` to this).
public struct GroceryDetectionInput: Sendable, Equatable {
  public let id: UUID
  public let ingredientId: Int64?
  public let label: String
  public let confidence: Float
  public let count: Int
  public let alternatives: [GroceryAlternative]

  public init(
    id: UUID = UUID(),
    ingredientId: Int64?,
    label: String,
    confidence: Float,
    count: Int = 1,
    alternatives: [GroceryAlternative] = []
  ) {
    self.id = id
    self.ingredientId = ingredientId
    self.label = label
    self.confidence = confidence
    self.count = count
    self.alternatives = alternatives
  }
}
