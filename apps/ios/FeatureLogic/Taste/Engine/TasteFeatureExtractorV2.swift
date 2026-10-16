import Foundation

/// Deterministic taste-feature extraction over the shipped bundle-v2 catalog —
/// the Swift twin of the lab's v2 loader
/// (`evaluation/taste-lab/taste_lab/features.py`, `_load_catalog_v2`).
/// Both sides must produce identical feature keys for the golden-fixture
/// replay to keep pinning engine behavior.
///
/// Feature classes for bundle v2 (the task's closed list; the legacy
/// extractor's `other:` class has no v2 source — the v2 bitmask is retired):
///
/// - `ingredient:<canonical key>` — required lines, INCLUDING assumed staples
///   (the meal uses them; feasibility never blocks on them, which is the
///   app's catalog-match rule).
/// - `cuisine:<cuisine>` — the bundle's own cuisine field (all six cuisines;
///   the legacy extractor restricted cuisine keys to three bitmask tags
///   because the legacy bitmask mixed cuisines with meal tags).
/// - `time:quick|weeknight|leisurely` — same thresholds as legacy (≤15, ≤30).
/// - `technique:<name>` — first two keyword classes found in title + steps.
/// - `spice:spicy` — one shared class key.
/// - `tool:<equipment>` — lowercased, spaces to underscores. The shipped
///   bundle carries no equipment today, so neither side emits tool keys.
/// - `nutrient:high_protein|high_fiber` — ONLY from `computed` or `estimated`
///   per-serving nutrition (protein ≥ 24 g, fiber ≥ 5 g). A `partial` recipe
///   never trains nutrient features: the bundle itself marks the numbers
///   unreliable.
///
/// Pure Swift: no GRDB, no app database.
public enum TasteFeatureExtractorV2 {
  static let techniqueKeywords: [(name: String, words: [String])] = [
    ("stir_fry", ["stir-fry", "stir fry", "wok", "sauté", "saute", "stir-fries"]),
    ("bake", ["bake", "oven", "preheat"]),
    ("grill", ["grill"]),
    ("steam", ["steam"]),
    ("boil", ["boil", "blanch"]),
    ("roast", ["roast"]),
    ("simmer", ["simmer", "braise"]),
    ("marinate", ["marinate", "marinade"]),
  ]
  static let spicyPatterns = [
    "chili", "chilli", "pepper flake", "sriracha", "sambal", "cayenne", "hot sauce",
    "jalape", "harissa", "gochujang", "curry paste",
  ]

  /// Extracts features for a whole bundle: recipe catalog id -> sorted feature
  /// keys, plus the feature-key -> display-name map (vocabulary display names
  /// lowercased for `ingredient:` keys, humanized suffixes otherwise).
  public static func extractCatalog(
    bundle: RecipeBundleV2
  ) -> (featureKeysByRecipe: [String: [String]], nameOf: [String: String]) {
    let ingredients = Dictionary(
      uniqueKeysWithValues: bundle.ingredients.map { ($0.key, $0.displayName) })
    var featureKeysByRecipe: [String: [String]] = [:]
    var nameOf: [String: String] = [:]
    for recipe in bundle.recipes {
      let (keys, names) = features(for: recipe, ingredientNames: ingredients)
      featureKeysByRecipe[recipe.catalogId] = keys
      for (key, name) in names where nameOf[key] == nil {
        nameOf[key] = name
      }
    }
    for keys in featureKeysByRecipe.values {
      for key in keys where nameOf[key] == nil {
        let suffix =
          key.split(separator: ":", maxSplits: 1).count > 1
          ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
        nameOf[key] = suffix.replacingOccurrences(of: "_", with: " ")
      }
    }
    return (featureKeysByRecipe, nameOf)
  }

  /// Fills the feature keys (canonical sorted order) and display names for one
  /// bundle recipe. Mirrors the lab's `_extract_features_v2` statement for
  /// statement.
  public static func features(
    for recipe: RecipeBundleRecipe, ingredientNames: [String: String]
  ) -> (keys: [String], names: [String: String]) {
    var keys: Set<String> = []
    var names: [String: String] = [:]

    // ingredient:<canonical key> — required lines only, including assumed
    // staples.
    for line in recipe.lines where line.required {
      let key = "ingredient:\(line.key)"
      if !keys.contains(key) {
        keys.insert(key)
        if let name = ingredientNames[line.key] {
          names[key] = name.lowercased()
        }
      }
    }

    let text = ([recipe.title] + recipe.steps.map(\.text)).joined(separator: "\n").lowercased()

    // cuisine:<cuisine> — one per recipe, from the bundle's cuisine field.
    keys.insert("cuisine:\(recipe.cuisine.rawValue)")

    // time buckets.
    if recipe.minutes <= 15 {
      keys.insert("time:quick")
    } else if recipe.minutes <= 30 {
      keys.insert("time:weeknight")
    } else {
      keys.insert("time:leisurely")
    }

    // technique:<name> — first two keyword classes found in title/steps.
    var found = 0
    for (name, words) in Self.techniqueKeywords where found < 2 {
      if words.contains(where: { text.contains($0) }) {
        keys.insert("technique:\(name)")
        found += 1
      }
    }

    // spice — one shared class key.
    if Self.spicyPatterns.contains(where: { text.contains($0) }) {
      keys.insert("spice:spicy")
    }

    // tool:<equipment> — normalized equipment strings.
    for entry in recipe.equipment {
      let normalized = entry.lowercased().replacingOccurrences(of: " ", with: "_")
      if !normalized.isEmpty {
        keys.insert("tool:\(normalized)")
      }
    }

    // nutrient — ONLY from computed or estimated per-serving nutrition.
    if recipe.nutrition.coverage == .computed || recipe.nutrition.coverage == .estimated {
      if recipe.nutrition.proteinG >= 24.0 {
        keys.insert("nutrient:high_protein")
      }
      if recipe.nutrition.fiberG >= 5.0 {
        keys.insert("nutrient:high_fiber")
      }
    }

    for key in keys where names[key] == nil {
      let suffix =
        key.split(separator: ":", maxSplits: 1).count > 1
        ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
      names[key] = suffix.replacingOccurrences(of: "_", with: " ")
    }

    return (keys.sorted(), names)
  }
}
