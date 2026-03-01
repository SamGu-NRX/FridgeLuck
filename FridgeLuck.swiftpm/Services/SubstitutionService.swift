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
  static func reasons(forRestrictions restrictions: Set<String>) -> Set<SubstitutionReason> {
    var result: Set<SubstitutionReason> = []
    if restrictions.contains("vegan") {
      result.formUnion([.vegan, .dairyFree, .vegetarian])
    }
    if restrictions.contains("vegetarian") {
      result.insert(.vegetarian)
    }
    if restrictions.contains("dairy_free") {
      result.formUnion([.dairyFree])
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

    // Sort: dietary-relevant subs first, then the rest.
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

  // Ingredient ID reference:
  //  1=egg, 2=rice, 3=soy_sauce, 4=chicken_breast, 5=onion,
  //  6=garlic, 7=tomato, 8=bell_pepper, 9=pasta, 10=potato,
  // 11=carrot, 12=cheese, 13=milk, 14=butter, 15=bread,
  // 16=olive_oil, 17=lemon, 18=mushroom, 19=spinach, 20=banana,
  // 21=green_onion, 22=sesame_oil, 23=tofu, 24=broccoli, 25=cucumber,
  // 26=avocado, 27=black_beans, 28=tortilla, 29=lime, 30=ginger,
  // 31=oats, 32=yogurt, 33=honey, 34=corn, 35=chickpea,
  // 36=salmon, 37=sweet_potato, 38=ground_beef, 39=lettuce, 40=apple,
  // 41=peanut_butter, 42=frozen_peas, 43=canned_tuna, 44=celery,
  // 45=zucchini, 46=red_pepper_flakes, 47=cumin, 48=cilantro,
  // 49=coconut_milk, 50=sour_cream

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

    // Butter (14) → Olive Oil (16)
    add(
      14, 16, reasons: [.vegan, .dairyFree, .lighter], ratio: 0.75,
      note: "Use 75% the weight in olive oil. Best for sauteing; less suited for baking.")

    // Butter (14) → Avocado (26)
    add(
      14, 26, reasons: [.vegan, .dairyFree], ratio: 1.0,
      note: "Mashed avocado works well in baking and spreads.")

    // Milk (13) → Coconut Milk (49)
    add(
      13, 49, reasons: [.vegan, .dairyFree], ratio: 1.0,
      note: "Full-fat coconut milk adds richness. Shake well before measuring.")

    // Cheese (12) → Tofu (23)
    add(
      12, 23, reasons: [.vegan, .dairyFree, .lighter], ratio: 1.2,
      note: "Crumbled firm tofu mimics ricotta or feta. Season well.")

    // Yogurt (32) → Coconut Milk (49)
    add(
      32, 49, reasons: [.vegan, .dairyFree], ratio: 0.9,
      note: "Thick coconut cream works as a yogurt stand-in for sauces and dressings.")

    // Sour Cream (50) → Yogurt (32)
    add(
      50, 32, reasons: [.lighter], ratio: 1.0,
      note: "Plain yogurt is a lighter, tangier alternative.")

    // Sour Cream (50) → Avocado (26)
    add(
      50, 26, reasons: [.vegan, .dairyFree], ratio: 0.8,
      note: "Blended avocado gives creamy richness without dairy.")

    // ── Vegan / Vegetarian Protein ──────────────────────

    // Chicken Breast (4) → Tofu (23)
    add(
      4, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Press tofu well and season generously for best results.")

    // Chicken Breast (4) → Chickpea (35)
    add(
      4, 35, reasons: [.vegan, .vegetarian], ratio: 1.3,
      note: "Chickpeas bring protein and hearty texture. Works great in stews and salads.")

    // Ground Beef (38) → Black Beans (27)
    add(
      38, 27, reasons: [.vegan, .vegetarian], ratio: 1.2,
      note: "Mashed black beans mimic ground meat texture in tacos and chili.")

    // Ground Beef (38) → Tofu (23)
    add(
      38, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Crumbled firm tofu, well-seasoned, works as a ground meat substitute.")

    // Salmon (36) → Tofu (23)
    add(
      36, 23, reasons: [.vegan, .vegetarian], ratio: 1.0,
      note: "Marinated tofu steaks are a good stand-in. Add nori for a seafood hint.")

    // Canned Tuna (43) → Chickpea (35)
    add(
      43, 35, reasons: [.vegan, .vegetarian], ratio: 1.2,
      note: "Mashed chickpeas with lemon and seasoning make a great 'tuna' salad.")

    // ── Gluten-Free ─────────────────────────────────────

    // Pasta (9) → Zucchini (45)
    add(
      9, 45, reasons: [.glutenFree, .lowCarb], ratio: 1.5,
      note: "Spiralized zucchini (zoodles) — lighter and gluten-free.")

    // Pasta (9) → Sweet Potato (37)
    add(
      9, 37, reasons: [.glutenFree], ratio: 1.0,
      note: "Cubed sweet potato adds body to sauces. Different but delicious.")

    // Bread (15) → Sweet Potato (37)
    add(
      15, 37, reasons: [.glutenFree], ratio: 1.0,
      note: "Sliced sweet potato rounds, toasted, work as bread for open sandwiches.")

    // Bread (15) → Lettuce (39)
    add(
      15, 39, reasons: [.glutenFree, .lowCarb], ratio: 0.5,
      note: "Lettuce wraps are a fresh, carb-free alternative to bread.")

    // Tortilla (28) → Lettuce (39)
    add(
      28, 39, reasons: [.glutenFree, .lowCarb], ratio: 0.5,
      note: "Large lettuce leaves make excellent taco or wrap shells.")

    // Oats (31) → Rice (2)
    add(
      31, 2, reasons: [.glutenFree], ratio: 1.0,
      note: "Cooked rice or rice flakes as a porridge base.")

    // ── Egg Substitute ──────────────────────────────────

    // Egg (1) → Banana (20)
    add(
      1, 20, reasons: [.vegan], ratio: 0.6,
      note: "Half a banana replaces one egg in baking. Adds mild sweetness.")

    // ── Sweetener ───────────────────────────────────────

    // Honey (33) → Banana (20)
    add(
      33, 20, reasons: [.vegan], ratio: 1.5,
      note: "Mashed banana provides natural sweetness. Adjust to taste.")

    // ── Flavor-Similar Swaps ────────────────────────────

    // Lemon (17) ↔ Lime (29)
    add(
      17, 29, reasons: [.similar], ratio: 1.0,
      note: "Interchangeable for most recipes. Lime is slightly more floral.")
    add(
      29, 17, reasons: [.similar], ratio: 1.0,
      note: "Lemon is a bit brighter than lime. Works as a direct swap.")

    // Onion (5) ↔ Green Onion (21)
    add(
      5, 21, reasons: [.similar], ratio: 0.7,
      note: "Green onion is milder. Use less and add near end of cooking.")
    add(
      21, 5, reasons: [.similar], ratio: 1.4,
      note: "Regular onion is stronger. Use a bit more and cook longer.")

    // ── Low-Carb / Lighter ──────────────────────────────

    // Potato (10) → Sweet Potato (37)
    add(
      10, 37, reasons: [.lighter], ratio: 1.0,
      note: "Sweet potato has more fiber and vitamins. Similar cooking method.")

    // Rice (2) → Broccoli (24)
    add(
      2, 24, reasons: [.lowCarb, .lighter], ratio: 1.0,
      note: "Riced broccoli is a low-carb base. Pulse raw broccoli in a food processor.")

    return map
  }
}
