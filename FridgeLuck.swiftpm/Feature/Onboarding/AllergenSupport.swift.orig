import Foundation

enum AllergenIcon: Hashable, Sendable {
  /// SF Symbol name (e.g. "drop.fill")
  case system(String)
  /// Asset-catalog image name (e.g. "allergen_shellfish")
  case named(String)

  var source: FLIconSource {
    switch self {
    case .system(let name):
      return .system(name)
    case .named(let name):
      return .asset(name)
    }
  }
}

struct AllergenGroupDefinition: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let subtitle: String
  let icon: AllergenIcon
  let keywords: [String]
}

struct AllergenIndexedIngredient: Identifiable, Sendable {
  let id: Int64
  let ingredient: Ingredient
  let searchableText: String
  let sortKey: String
  let group: AllergenGroupDefinition?

  var displayName: String {
    ingredient.displayName
  }

  var groupTitle: String {
    group?.title ?? "Other"
  }
}

struct AllergenCatalogSection: Identifiable, Sendable {
  let id: String
  let title: String
  let ingredients: [AllergenIndexedIngredient]
}

struct AllergenCatalogIndex: Sendable {
  let allIngredients: [AllergenIndexedIngredient]
  let relevantIngredients: [AllergenIndexedIngredient]
  let ingredientsByID: [Int64: Ingredient]
  let groupMatchesByID: [String: Set<Int64>]
  let allSections: [AllergenCatalogSection]
  let relevantSections: [AllergenCatalogSection]

  static let empty = AllergenCatalogIndex(
    allIngredients: [],
    relevantIngredients: [],
    ingredientsByID: [:],
    groupMatchesByID: Dictionary(
      uniqueKeysWithValues: AllergenSupport.groups.map { ($0.id, Set<Int64>()) }),
    allSections: [],
    relevantSections: []
  )

  func sections(matching query: String, includeAllIngredients: Bool) -> [AllergenCatalogSection] {
    guard !query.isEmpty else {
      return includeAllIngredients ? allSections : relevantSections
    }

    let source = includeAllIngredients ? allIngredients : relevantIngredients
    let filtered = source.filter { $0.searchableText.contains(query) }
    return AllergenSupport.makeSections(from: filtered)
  }

  func selectedIngredients(from ids: Set<Int64>) -> [Ingredient] {
    ids
      .compactMap { ingredientsByID[$0] }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }
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
      icon: .named("allergen_milk"),
      keywords: ["milk", "cream", "cheese", "butter", "yogurt", "ghee", "whey", "casein"]
    ),
    .init(
      id: "egg",
      title: "Egg",
      subtitle: "Egg",
      icon: .named("allergen_egg"),
      keywords: ["egg", "albumin", "mayonnaise", "mayo"]
    ),
    .init(
      id: "peanut",
      title: "Peanut",
      subtitle: "Legume",
      icon: .named("allergen_peanut"),
      keywords: ["peanut", "groundnut"]
    ),
    .init(
      id: "tree_nut",
      title: "Tree Nuts",
      subtitle: "Almond, walnut, etc.",
      icon: .named("allergen_treenut"),
      keywords: [
        "almond", "walnut", "cashew", "pecan", "hazelnut", "pistachio", "macadamia",
        "brazil nut", "pine nut", "tree nut",
      ]
    ),
    .init(
      id: "soy",
      title: "Soy",
      subtitle: "Soybean",
      icon: .named("allergen_soy"),
      keywords: ["soy", "soybean", "tofu", "edamame", "miso", "tempeh"]
    ),
    .init(
      id: "wheat_gluten",
      title: "Gluten",
      subtitle: "Wheat, barley, rye",
      icon: .named("allergen_gluten"),
      keywords: ["wheat", "flour", "gluten", "barley", "rye", "semolina", "spelt"]
    ),
    .init(
      id: "fish",
      title: "Fish",
      subtitle: "Fin fish",
      icon: .named("allergen_fish"),
      keywords: ["fish", "salmon", "tuna", "cod", "anchovy", "sardine", "mackerel", "halibut"]
    ),
    .init(
      id: "shellfish",
      title: "Shellfish",
      subtitle: "Shrimp, crab, oyster",
      icon: .named("allergen_shellfish"),
      keywords: [
        "shrimp", "prawn", "crab", "lobster", "clam", "mussel", "oyster", "scallop", "shellfish",
      ]
    ),
    .init(
      id: "sesame",
      title: "Sesame",
      subtitle: "Seeds/tahini",
      icon: .named("allergen_sesame"),
      keywords: ["sesame", "tahini"]
    ),
    .init(
      id: "mustard",
      title: "Mustard",
      subtitle: "Mustard seed",
      icon: .named("allergen_mustard"),
      keywords: ["mustard"]
    ),
  ]

  static func buildCatalog(from ingredients: [Ingredient]) -> AllergenCatalogIndex {
    var indexedIngredients: [AllergenIndexedIngredient] = []
    indexedIngredients.reserveCapacity(ingredients.count)

    var ingredientsByID: [Int64: Ingredient] = [:]
    ingredientsByID.reserveCapacity(ingredients.count)

    var groupMatchesByID = Dictionary(
      uniqueKeysWithValues: groups.map { ($0.id, Set<Int64>()) }
    )

    for ingredient in ingredients {
      guard let id = ingredient.id else { continue }

      let searchableText = normalizedSearchableText(for: ingredient)
      let matchedGroup = group(forNormalizedText: searchableText)

      ingredientsByID[id] = ingredient
      if let matchedGroup {
        groupMatchesByID[matchedGroup.id, default: []].insert(id)
      }

      indexedIngredients.append(
        AllergenIndexedIngredient(
          id: id,
          ingredient: ingredient,
          searchableText: searchableText,
          sortKey: sortableName(for: ingredient),
          group: matchedGroup
        )
      )
    }

    indexedIngredients.sort { $0.sortKey < $1.sortKey }

    let relevantIngredients = indexedIngredients.filter { $0.group != nil }

    return AllergenCatalogIndex(
      allIngredients: indexedIngredients,
      relevantIngredients: relevantIngredients,
      ingredientsByID: ingredientsByID,
      groupMatchesByID: groupMatchesByID,
      allSections: makeSections(from: indexedIngredients),
      relevantSections: makeSections(from: relevantIngredients)
    )
  }

  static func matchingIDs(for group: AllergenGroupDefinition, in ingredients: [Ingredient]) -> Set<
    Int64
  > {
    buildCatalog(from: ingredients).groupMatchesByID[group.id] ?? []
  }

  /// Builds one pass of allergen group matches so UI can avoid repeated O(n*m) rescans.
  static func groupMatchesByGroupID(in ingredients: [Ingredient]) -> [String: Set<Int64>] {
    buildCatalog(from: ingredients).groupMatchesByID
  }

  static func group(for ingredient: Ingredient) -> AllergenGroupDefinition? {
    group(forNormalizedText: normalizedSearchableText(for: ingredient))
  }

  static func relevantIngredients(in ingredients: [Ingredient]) -> [Ingredient] {
    buildCatalog(from: ingredients).relevantIngredients.map(\.ingredient)
  }

  static func searchableText(for ingredient: Ingredient) -> String {
    normalizedSearchableText(for: ingredient)
  }

  static func normalizedQuery(_ raw: String) -> String {
    normalize(raw)
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

  private static func group(forNormalizedText text: String) -> AllergenGroupDefinition? {
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

  private static func normalizedSearchableText(for ingredient: Ingredient) -> String {
    normalize(
      [
        ingredient.name,
        ingredient.displayName,
        ingredient.description ?? "",
        ingredient.categoryLabel ?? "",
        ingredient.notes ?? "",
      ]
      .joined(separator: " ")
    )
  }

  private static func sortableName(for ingredient: Ingredient) -> String {
    ingredient.displayName.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
  }

  fileprivate static func makeSections(
    from ingredients: [AllergenIndexedIngredient]
  ) -> [AllergenCatalogSection] {
    let grouped = Dictionary(grouping: ingredients) { $0.groupTitle }
    var ordered: [AllergenCatalogSection] = []

    for group in groups {
      if let items = grouped[group.title], !items.isEmpty {
        ordered.append(.init(id: group.id, title: group.title, ingredients: items))
      }
    }

    if let other = grouped["Other"], !other.isEmpty {
      ordered.append(.init(id: "other", title: "Other", ingredients: other))
    }

    return ordered
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
