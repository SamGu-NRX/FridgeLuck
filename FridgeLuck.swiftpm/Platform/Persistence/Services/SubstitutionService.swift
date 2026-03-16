import Foundation
import GRDB

// MARK: - Substitution Reason

/// Why this substitution exists — displayed as badges in the UI.
enum SubstitutionReason: String, Sendable, CaseIterable {
  case vegan = "Vegan"
  case dairyFree = "Dairy-Free"
  case glutenFree = "Gluten-Free"
  case vegetarian = "Vegetarian"
  case lighter = "Lighter"
  case lowCarb = "Low-Carb"
  case similar = "Similar Flavor"

  var icon: String {
    switch self {
    case .vegan: "leaf.fill"
    case .dairyFree: "drop.degreesign.slash"
    case .glutenFree: "xmark.seal.fill"
    case .vegetarian: "leaf"
    case .lighter: "scalemass"
    case .lowCarb: "chart.bar.xaxis.ascending"
    case .similar: "arrow.triangle.swap"
    }
  }

  /// Map dietary restriction IDs to relevant reasons.
  ///
  /// With the simplified diet model (classic/pescatarian/vegetarian/vegan/keto),
  /// only the single selected diet is passed in the restrictions set.
  /// Gluten-free and dairy-free are now handled by the allergen system.
  static func reasons(forRestrictions restrictions: Set<String>) -> Set<SubstitutionReason> {
    var result: Set<SubstitutionReason> = []

    if restrictions.contains("vegan") {
      result.formUnion([.vegan, .dairyFree, .vegetarian])
    } else if restrictions.contains("vegetarian") || restrictions.contains("pescatarian") {
      result.insert(.vegetarian)
    }

    if restrictions.contains("keto") {
      result.insert(.lowCarb)
    }

    // Legacy support: if older profiles still have these IDs, honor them
    if restrictions.contains("dairy_free") {
      result.insert(.dairyFree)
    }
    if restrictions.contains("gluten_free") {
      result.insert(.glutenFree)
    }
    if restrictions.contains("low_carb") {
      result.insert(.lowCarb)
    }

    return result
  }
}

// MARK: - Substitution Entry

/// A single ingredient substitution: replace `originalId` with `substituteId`.
struct Substitution: Sendable, Identifiable {
  var id: String { "\(originalId)-\(substituteId)" }
  let originalId: Int64
  let substituteId: Int64
  let reasons: Set<SubstitutionReason>
  /// Gram-for-gram ratio. 1.0 = same weight. e.g. 0.8 means use 80% of the original weight.
  let ratio: Double

  /// Human-readable note for the cook.
  let note: String?
}

// MARK: - Substitution Service

/// Pure-logic service. Holds the substitution map and resolves options for a given
/// ingredient + user dietary context. No database writes — all data is static.
final class SubstitutionService: Sendable {
  private let db: DatabaseQueue

  /// Static substitution pairs keyed by original ingredient ID.
  private let substitutionMap: [Int64: [Substitution]]

  init(db: DatabaseQueue) {
    self.db = db
    self.substitutionMap = Self.buildMap()
  }

  // MARK: - Queries

  /// All substitutes for a given ingredient, optionally filtered by user's dietary context.
  /// When `dietaryRestrictions` is non-empty, substitutes whose reasons match are sorted first.
  func substitutions(
    for ingredientId: Int64,
    dietaryRestrictions: Set<String> = []
  ) -> [Substitution] {
    guard let subs = substitutionMap[ingredientId], !subs.isEmpty else { return [] }

    if dietaryRestrictions.isEmpty { return subs }

    let relevantReasons = SubstitutionReason.reasons(forRestrictions: dietaryRestrictions)

    return subs.sorted { a, b in
      let aRelevant = !a.reasons.isDisjoint(with: relevantReasons)
      let bRelevant = !b.reasons.isDisjoint(with: relevantReasons)
      if aRelevant != bRelevant { return aRelevant }
      return a.substituteId < b.substituteId
    }
  }

  /// Quick check: does this ingredient have any substitution?
  func hasSubstitutions(for ingredientId: Int64) -> Bool {
    guard let subs = substitutionMap[ingredientId] else { return false }
    return !subs.isEmpty
  }

  /// Fetch the `Ingredient` model for a substitute ID (for nutritional comparison).
  func ingredient(id: Int64) throws -> Ingredient? {
    try db.read { db in
      try Ingredient.fetchOne(db, key: id)
    }
  }

  // MARK: - Static Substitution Map

  private static func buildMap() -> [Int64: [Substitution]] {
    var map: [Int64: [Substitution]] = [:]

    func add(
      _ originalId: Int64, _ substituteId: Int64,
      reasons: Set<SubstitutionReason>, ratio: Double = 1.0, note: String? = nil
    ) {
      let sub = Substitution(
        originalId: originalId,
        substituteId: substituteId,
        reasons: reasons,
        ratio: ratio,
        note: note
      )
      map[originalId, default: []].append(sub)
    }

    // ── Dairy-Free / Vegan ──────────────────────────────
    add(
      14, 16, reasons: [.vegan, .dairyFree, .lighter], ratio: 0.75,
      note: "Use 75% the weight in olive oil. Best for sauteing; less suited for baking.")
    add(
      14, 26, reasons: [.vegan, .dairyFree], ratio: 1.0,
      note: "Mashed avocado works well in baking and spreads.")
    add(
      13, 49, reasons: [.vegan, .dairyFree], ratio: 1.0,
      note: "Full-fat coconut milk adds richness. Shake well before measuring.")
    add(
      12, 23, reasons: [.vegan, .dairyFree, .lighter], ratio: 1.2,
      note: "Crumbled firm tofu mimics ricotta or feta. Season well.")
    add(
      32, 49, reasons: [.vegan, .dairyFree], ratio: 0.9,
      note: "Thick coconut cream works as a yogurt stand-in for sauces and dressings.")
    add(
      50, 32, reasons: [.lighter], ratio: 1.0,
      note: "Plain yogurt is a lighter, tangier alternative.")
    add(
      50, 26, reasons: [.vegan, .dairyFree], ratio: 0.8,
      note: "Blended avocado gives creamy richness without dairy.")

    // ── Vegan / Vegetarian Protein ──────────────────────
    add(
      4, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Press tofu well and season generously for best results.")
    add(
      4, 35, reasons: [.vegan, .vegetarian], ratio: 1.3,
      note: "Chickpeas bring protein and hearty texture. Works great in stews and salads.")
    add(
      38, 27, reasons: [.vegan, .vegetarian], ratio: 1.2,
      note: "Mashed black beans mimic ground meat texture in tacos and chili.")
    add(
      38, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Crumbled firm tofu, well-seasoned, works as a ground meat substitute.")
    add(
      36, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Marinated tofu steaks are a good stand-in. Add nori for a seafood hint.")
    add(
      43, 35, reasons: [.vegan, .vegetarian], ratio: 1.2,
      note: "Mashed chickpeas with lemon and seasoning make a great 'tuna' salad.")

    // ── Gluten-Free ─────────────────────────────────────
    add(
      9, 45, reasons: [.glutenFree, .lowCarb], ratio: 1.5,
      note: "Spiralized zucchini (zoodles) — lighter and gluten-free.")
    add(
      9, 37, reasons: [.glutenFree], ratio: 1.0,
      note: "Cubed sweet potato adds body to sauces. Different but delicious.")
    add(
      15, 37, reasons: [.glutenFree], ratio: 1.0,
      note: "Sliced sweet potato rounds, toasted, work as bread for open sandwiches.")
    add(
      15, 39, reasons: [.glutenFree, .lowCarb], ratio: 0.5,
      note: "Lettuce wraps are a fresh, carb-free alternative to bread.")
    add(
      28, 39, reasons: [.glutenFree, .lowCarb], ratio: 0.5,
      note: "Large lettuce leaves make excellent taco or wrap shells.")
    add(
      31, 2, reasons: [.glutenFree], ratio: 1.0,
      note: "Cooked rice or rice flakes as a porridge base.")

    // ── Egg Substitute ──────────────────────────────────
    add(
      1, 20, reasons: [.vegan], ratio: 0.6,
      note: "Half a banana replaces one egg in baking. Adds mild sweetness.")

    // ── Sweetener ───────────────────────────────────────
    add(
      33, 20, reasons: [.vegan], ratio: 1.5,
      note: "Mashed banana provides natural sweetness. Adjust to taste.")

    // ── Flavor-Similar Swaps ────────────────────────────
    add(
      17, 29, reasons: [.similar], ratio: 1.0,
      note: "Interchangeable for most recipes. Lime is slightly more floral.")
    add(
      29, 17, reasons: [.similar], ratio: 1.0,
      note: "Lemon is a bit brighter than lime. Works as a direct swap.")
    add(
      5, 21, reasons: [.similar], ratio: 0.7,
      note: "Green onion is milder. Use less and add near end of cooking.")
    add(
      21, 5, reasons: [.similar], ratio: 1.4,
      note: "Regular onion is stronger. Use a bit more and cook longer.")

    // ── Low-Carb / Lighter ──────────────────────────────
    add(
      10, 37, reasons: [.lighter], ratio: 1.0,
      note: "Sweet potato has more fiber and vitamins. Similar cooking method.")
    add(
      2, 24, reasons: [.lowCarb, .lighter], ratio: 1.0,
      note: "Riced broccoli is a low-carb base. Pulse raw broccoli in a food processor.")

    return map
  }
}
