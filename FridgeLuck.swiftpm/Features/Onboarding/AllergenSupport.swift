import Foundation

struct AllergenGroupDefinition: Identifiable, Hashable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  let keywords: [String]
}

enum AllergenSupport {
  private static let nutButterQualifiers: [String] = [
    "peanut",
    "almond",
    "cashew",
    "hazelnut",
    "pistachio",
    "walnut",
    "sesame",
    "sunflower",
    "soy",
  ]

  static let groups: [AllergenGroupDefinition] = [
    .init(
      id: "milk",
      title: "Milk",
      subtitle: "Dairy",
      systemImage: "drop.fill",
      keywords: ["milk", "cream", "cheese", "butter", "yogurt", "ghee", "whey", "casein"]
    ),
    .init(
      id: "egg",
      title: "Egg",
      subtitle: "Egg",
      systemImage: "circle.fill",
      keywords: ["egg", "albumin", "mayonnaise", "mayo"]
    ),
    .init(
      id: "peanut",
      title: "Peanut",
      subtitle: "Legume",
      systemImage: "circle.hexagongrid.fill",
      keywords: ["peanut", "groundnut"]
    ),
    .init(
      id: "tree_nut",
      title: "Tree Nuts",
      subtitle: "Almond, walnut, etc.",
      systemImage: "leaf.circle.fill",
      keywords: [
        "almond", "walnut", "cashew", "pecan", "hazelnut", "pistachio", "macadamia",
        "brazil nut", "pine nut", "tree nut",
      ]
    ),
    .init(
      id: "soy",
      title: "Soy",
      subtitle: "Soybean",
      systemImage: "capsule.fill",
      keywords: ["soy", "soybean", "tofu", "edamame", "miso", "tempeh"]
    ),
    .init(
      id: "wheat_gluten",
      title: "Wheat/Gluten",
      subtitle: "Wheat family",
      systemImage: "takeoutbag.and.cup.and.straw.fill",
      keywords: ["wheat", "flour", "gluten", "barley", "rye", "semolina", "spelt"]
    ),
    .init(
      id: "fish",
      title: "Fish",
      subtitle: "Fin fish",
      systemImage: "fish.fill",
      keywords: ["fish", "salmon", "tuna", "cod", "anchovy", "sardine", "mackerel", "halibut"]
    ),
    .init(
      id: "shellfish",
      title: "Shellfish",
      subtitle: "Crustacean/mollusk",
      systemImage: "tortoise.fill",
      keywords: [
        "shrimp", "prawn", "crab", "lobster", "clam", "mussel", "oyster", "scallop", "shellfish",
      ]
    ),
    .init(
      id: "sesame",
      title: "Sesame",
      subtitle: "Seeds/tahini",
      systemImage: "smallcircle.filled.circle",
      keywords: ["sesame", "tahini"]
    ),
    .init(
      id: "mustard",
      title: "Mustard",
      subtitle: "Mustard seed",
      systemImage: "circle.grid.cross.fill",
      keywords: ["mustard"]
    ),
  ]

  static func matchingIDs(for group: AllergenGroupDefinition, in ingredients: [Ingredient]) -> Set<
    Int64
  > {
    var ids = Set<Int64>()

    for ingredient in ingredients {
      guard let id = ingredient.id else { continue }
      if self.group(for: ingredient)?.id == group.id {
        ids.insert(id)
      }
    }

    return ids
  }

  /// Builds one pass of allergen group matches so UI can avoid repeated O(n*m) rescans.
  static func groupMatchesByGroupID(in ingredients: [Ingredient]) -> [String: Set<Int64>] {
    var matches: [String: Set<Int64>] = [:]
    matches.reserveCapacity(groups.count)
    for group in groups {
      matches[group.id] = []
    }

    for ingredient in ingredients {
      guard let id = ingredient.id else { continue }
      guard let group = self.group(for: ingredient) else { continue }
      matches[group.id, default: []].insert(id)
    }

    return matches
  }

  static func group(for ingredient: Ingredient) -> AllergenGroupDefinition? {
    let text = normalizedSearchableText(for: ingredient)
    guard !text.isEmpty else { return nil }

    var best: (group: AllergenGroupDefinition, score: Int)?

    for group in groups {
      let score = score(for: group, in: text)
      guard score > 0 else { continue }

      if let currentBest = best {
        if score > currentBest.score {
          best = (group, score)
        }
      } else {
        best = (group, score)
      }
    }

    return best?.group
  }

  static func relevantIngredients(in ingredients: [Ingredient]) -> [Ingredient] {
    ingredients
      .filter { ingredient in
        guard ingredient.id != nil else { return false }
        return group(for: ingredient) != nil
      }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  static func searchableText(for ingredient: Ingredient) -> String {
    [
      ingredient.name,
      ingredient.displayName,
      ingredient.description ?? "",
      ingredient.categoryLabel ?? "",
      ingredient.notes ?? "",
    ]
    .joined(separator: " ")
    .lowercased()
  }

  private static func score(for group: AllergenGroupDefinition, in text: String) -> Int {
    var score = 0

    for keyword in group.keywords {
      guard containsTerm(keyword, in: text) else { continue }

      if group.id == "milk", keyword == "butter",
        nutButterQualifiers.contains(where: { containsTerm("\($0) butter", in: text) })
      {
        continue
      }

      score += keywordWeight(for: keyword)
    }

    return score
  }
  private static func keywordWeight(for keyword: String) -> Int {
    if keyword.contains(" ") {
      return 4
    }
    if keyword.count >= 6 {
      return 3
    }
    if keyword.count >= 4 {
      return 2
    }
    return 1
  }

  private static func containsTerm(_ term: String, in text: String) -> Bool {
    let normalizedTerm = normalize(term)
    guard !normalizedTerm.isEmpty else { return false }
    return " \(text) ".contains(" \(normalizedTerm) ")
  }

  private static func normalizedSearchableText(for ingredient: Ingredient) -> String {
    normalize(searchableText(for: ingredient))
  }

  private static func normalize(_ raw: String) -> String {
    let space = UnicodeScalar(32)!
    let scalars = raw.lowercased().unicodeScalars.map { scalar -> UnicodeScalar in
      CharacterSet.alphanumerics.contains(scalar) ? scalar : space
    }
    let rawNormalized = String(String.UnicodeScalarView(scalars))
    return
      rawNormalized
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
