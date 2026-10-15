import Foundation

// MARK: - Vocabulary

/// The six-cuisine vocabulary of bundle v2, extended only by a spec revision.
public enum RecipeCatalogCuisine: String, Codable, Sendable, CaseIterable {
  case american
  case asian
  case indian
  case italian
  case mediterranean
  case mexican
}

public enum RecipeCatalogMealSlot: String, Codable, Sendable, CaseIterable {
  case breakfast
  case lunch
  case dinner
  case snack
  case dessert
}

public enum RecipeCatalogCollection: String, Codable, Sendable, CaseIterable {
  case quick
  case budget
  case onePot = "one_pot"
  case comfort
  case useSoon = "use_soon"
}

/// How much the per-serving nutrition can be trusted. `computed` means every weighed line
/// had a per-100 g row; `estimated` means household/count conversions were applied;
/// `partial` means some lines carry no nutrition at all.
public enum RecipeCatalogNutritionCoverage: String, Codable, Sendable {
  case computed
  case estimated
  case partial
}

/// Rights status. Unknown rights means quarantine (fail-closed, overhaul spec 3.5):
/// `quarantined` rows are display-only and excluded from sharing.
public enum RecipeCatalogRightsStatus: String, Codable, Sendable {
  case original
  case quarantined
}

/// The stable public identity of a recipe, per the burst5 shared contracts:
/// `RecipeRef = {source, id, revision}`.
public enum RecipeRefSource: String, Codable, Sendable {
  case catalog
  case user
  case community
  case generated
}

public struct RecipeRef: Codable, Equatable, Sendable {
  public let source: RecipeRefSource
  public let id: String
  public let revision: Int

  public init(source: RecipeRefSource, id: String, revision: Int) {
    self.source = source
    self.id = id
    self.revision = revision
  }

  public static func catalog(id: String, revision: Int) -> RecipeRef {
    RecipeRef(source: .catalog, id: id, revision: revision)
  }
}

// MARK: - Quantity

/// Quantity evidence for one ingredient line. `unknown` carries a human note ("to taste")
/// and never a guessed gram value; a `household` line carries grams only when the
/// conversion is evidence-backed (MassConversionKit), else `nil`.
public enum RecipeCatalogQuantity: Equatable, Sendable {
  case grams(Double)
  case count(amount: Double, unit: String, grams: Double?)
  case household(amount: Double, unit: String, grams: Double?)
  case unknown(note: String?)
}

extension RecipeCatalogQuantity: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, grams, amount, unit, note
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "grams":
      self = .grams(try container.decode(Double.self, forKey: .grams))
    case "count":
      self = .count(
        amount: try container.decode(Double.self, forKey: .amount),
        unit: try container.decode(String.self, forKey: .unit),
        grams: try container.decodeIfPresent(Double.self, forKey: .grams)
      )
    case "household":
      self = .household(
        amount: try container.decode(Double.self, forKey: .amount),
        unit: try container.decode(String.self, forKey: .unit),
        grams: try container.decodeIfPresent(Double.self, forKey: .grams)
      )
    case "unknown":
      self = .unknown(note: try container.decodeIfPresent(String.self, forKey: .note))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container,
        debugDescription: "unknown quantity kind: \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .grams(let grams):
      try container.encode("grams", forKey: .kind)
      try container.encode(grams, forKey: .grams)
    case .count(let amount, let unit, let grams):
      try container.encode("count", forKey: .kind)
      try container.encode(amount, forKey: .amount)
      try container.encode(unit, forKey: .unit)
      try container.encodeIfPresent(grams, forKey: .grams)
    case .household(let amount, let unit, let grams):
      try container.encode("household", forKey: .kind)
      try container.encode(amount, forKey: .amount)
      try container.encode(unit, forKey: .unit)
      try container.encodeIfPresent(grams, forKey: .grams)
    case .unknown(let note):
      try container.encode("unknown", forKey: .kind)
      try container.encodeIfPresent(note, forKey: .note)
    }
  }
}

// MARK: - Ingredient vocabulary

public struct RecipeCatalogPer100g: Codable, Equatable, Sendable {
  public let kcal: Double
  public let proteinG: Double
  public let carbsG: Double
  public let fatG: Double
  public let fiberG: Double
  public let sugarG: Double
  public let sodiumMg: Double

  public init(
    kcal: Double, proteinG: Double, carbsG: Double, fatG: Double,
    fiberG: Double, sugarG: Double, sodiumMg: Double
  ) {
    self.kcal = kcal
    self.proteinG = proteinG
    self.carbsG = carbsG
    self.fatG = fatG
    self.fiberG = fiberG
    self.sugarG = sugarG
    self.sodiumMg = sodiumMg
  }

  private enum CodingKeys: String, CodingKey {
    case kcal
    case proteinG = "protein_g"
    case carbsG = "carbs_g"
    case fatG = "fat_g"
    case fiberG = "fiber_g"
    case sugarG = "sugar_g"
    case sodiumMg = "sodium_mg"
  }
}

/// One entry of the canonical ingredient vocabulary. `fdcId` and `legacyId` are nullable
/// evidence links; nothing in the app joins on integer ids.
public struct RecipeCatalogIngredient: Codable, Equatable, Sendable {
  public let key: String
  public let fdcId: Int64?
  public let legacyId: Int64?
  public let displayName: String
  public let category: String
  public let per100g: RecipeCatalogPer100g?
  public let aliases: [String]

  public init(
    key: String, fdcId: Int64?, legacyId: Int64?, displayName: String,
    category: String, per100g: RecipeCatalogPer100g?, aliases: [String]
  ) {
    self.key = key
    self.fdcId = fdcId
    self.legacyId = legacyId
    self.displayName = displayName
    self.category = category
    self.per100g = per100g
    self.aliases = aliases
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case fdcId = "fdc_id"
    case legacyId = "legacy_id"
    case displayName = "display_name"
    case category
    case per100g = "per_100g"
    case aliases
  }
}

// MARK: - Lines, steps, checks

public struct RecipeCatalogLine: Codable, Equatable, Sendable {
  public let key: String
  public let quantity: RecipeCatalogQuantity
  public let required: Bool
  public let assumedStaple: Bool
  public let note: String?

  public init(
    key: String, quantity: RecipeCatalogQuantity,
    required: Bool, assumedStaple: Bool, note: String?
  ) {
    self.key = key
    self.quantity = quantity
    self.required = required
    self.assumedStaple = assumedStaple
    self.note = note
  }

  private enum CodingKeys: String, CodingKey {
    case key, quantity, required
    case assumedStaple = "assumed_staple"
    case note
  }
}

/// A thermometer check with an endpoint temperature and a pinned source
/// (e.g. `usda-fsis: ground beef 160 F`). The camera never issues a verdict.
public struct RecipeCatalogThermometer: Codable, Equatable, Sendable {
  public let endpointC: Double
  public let food: String
  public let source: String

  public init(endpointC: Double, food: String, source: String) {
    self.endpointC = endpointC
    self.food = food
    self.source = source
  }

  private enum CodingKeys: String, CodingKey {
    case endpointC = "endpoint_c"
    case food, source
  }
}

public struct RecipeCatalogStep: Codable, Equatable, Sendable {
  public let text: String
  /// Indexes into the recipe's ingredient lines this step consumes.
  public let uses: [Int]
  public let timerSeconds: Int?
  public let thermometer: RecipeCatalogThermometer?

  public init(
    text: String, uses: [Int], timerSeconds: Int?, thermometer: RecipeCatalogThermometer?
  ) {
    self.text = text
    self.uses = uses
    self.timerSeconds = timerSeconds
    self.thermometer = thermometer
  }

  private enum CodingKeys: String, CodingKey {
    case text, uses
    case timerSeconds = "timer_seconds"
    case thermometer
  }
}

// MARK: - Recipe

/// Diet claims. `nil` means unknown and every restriction check treats it as "fails" —
/// the same fail-closed rule as the allergen engine.
public struct RecipeCatalogClaims: Codable, Equatable, Sendable {
  public let vegetarian: Bool?
  public let vegan: Bool?
  public let glutenFree: Bool?
  public let dairyFree: Bool?

  public init(vegetarian: Bool?, vegan: Bool?, glutenFree: Bool?, dairyFree: Bool?) {
    self.vegetarian = vegetarian
    self.vegan = vegan
    self.glutenFree = glutenFree
    self.dairyFree = dairyFree
  }

  private enum CodingKeys: String, CodingKey {
    case vegetarian, vegan
    case glutenFree = "gluten_free"
    case dairyFree = "dairy_free"
  }
}

public struct RecipeCatalogNutrition: Codable, Equatable, Sendable {
  public let kcal: Double
  public let proteinG: Double
  public let carbsG: Double
  public let fatG: Double
  public let fiberG: Double
  public let sodiumMg: Double
  public let coverage: RecipeCatalogNutritionCoverage
  public let basis: String

  public init(
    kcal: Double, proteinG: Double, carbsG: Double, fatG: Double,
    fiberG: Double, sodiumMg: Double, coverage: RecipeCatalogNutritionCoverage, basis: String
  ) {
    self.kcal = kcal
    self.proteinG = proteinG
    self.carbsG = carbsG
    self.fatG = fatG
    self.fiberG = fiberG
    self.sodiumMg = sodiumMg
    self.coverage = coverage
    self.basis = basis
  }

  private enum CodingKeys: String, CodingKey {
    case kcal
    case proteinG = "protein_g"
    case carbsG = "carbs_g"
    case fatG = "fat_g"
    case fiberG = "fiber_g"
    case sodiumMg = "sodium_mg"
    case coverage, basis
  }
}

public struct RecipeCatalogRights: Codable, Equatable, Sendable {
  public let status: RecipeCatalogRightsStatus
  public let evidence: String

  public init(status: RecipeCatalogRightsStatus, evidence: String) {
    self.status = status
    self.evidence = evidence
  }

  private enum CodingKeys: String, CodingKey {
    case status, evidence
  }
}

/// A bundle v2 recipe: stable `catalogId` (`rcp-NNNNNN`) plus `revision`.
public struct RecipeBundleRecipe: Codable, Equatable, Sendable {
  public let catalogId: String
  public let revision: Int
  public let title: String
  public let cuisine: RecipeCatalogCuisine
  public let mealSlots: [RecipeCatalogMealSlot]
  public let collections: [RecipeCatalogCollection]
  public let minutes: Int
  public let servings: Int
  public let equipment: [String]
  public let lines: [RecipeCatalogLine]
  public let steps: [RecipeCatalogStep]
  public let claims: RecipeCatalogClaims
  public let nutrition: RecipeCatalogNutrition
  public let rights: RecipeCatalogRights
  public let keywords: [String]

  private enum CodingKeys: String, CodingKey {
    case catalogId = "catalog_id"
    case revision, title, cuisine
    case mealSlots = "meal_slots"
    case collections, minutes, servings, equipment
    case ingredients
    case steps, claims
    case nutrition = "nutrition_per_serving"
    case rights, keywords
  }
}

// MARK: - Catalog recipe (read path)

/// The recipe a detail screen or cook mode renders. Bundle v2 rows carry structured lines
/// and steps; rows hydrated from the legacy data.json carry empty `steps` and `nil`
/// nutrition, and the legacy instructions path still renders them.
public struct RecipeCatalogRecipe: Equatable, Sendable {
  public let catalogId: String
  public let revision: Int
  public let title: String
  public let cuisine: RecipeCatalogCuisine
  public let mealSlots: [RecipeCatalogMealSlot]
  public let collections: [RecipeCatalogCollection]
  public let minutes: Int
  public let servings: Int
  public let equipment: [String]
  public let lines: [RecipeCatalogLine]
  public let steps: [RecipeCatalogStep]
  public let claims: RecipeCatalogClaims
  public let nutrition: RecipeCatalogNutrition?
  public let rights: RecipeCatalogRights
  public let keywords: [String]
  /// The legacy `recipes.id` this row succeeds, when one exists.
  public let legacyRecipeId: Int64?

  public init(
    catalogId: String, revision: Int, title: String, cuisine: RecipeCatalogCuisine,
    mealSlots: [RecipeCatalogMealSlot], collections: [RecipeCatalogCollection],
    minutes: Int, servings: Int, equipment: [String],
    lines: [RecipeCatalogLine], steps: [RecipeCatalogStep],
    claims: RecipeCatalogClaims, nutrition: RecipeCatalogNutrition?,
    rights: RecipeCatalogRights, keywords: [String], legacyRecipeId: Int64?
  ) {
    self.catalogId = catalogId
    self.revision = revision
    self.title = title
    self.cuisine = cuisine
    self.mealSlots = mealSlots
    self.collections = collections
    self.minutes = minutes
    self.servings = servings
    self.equipment = equipment
    self.lines = lines
    self.steps = steps
    self.claims = claims
    self.nutrition = nutrition
    self.rights = rights
    self.keywords = keywords
    self.legacyRecipeId = legacyRecipeId
  }

  public var ref: RecipeRef {
    RecipeRef.catalog(id: catalogId, revision: revision)
  }
}

extension RecipeBundleRecipe {
  /// The bundle form of this recipe as a catalog read model, without a legacy link.
  public var asCatalogRecipe: RecipeCatalogRecipe {
    RecipeCatalogRecipe(
      catalogId: catalogId, revision: revision, title: title, cuisine: cuisine,
      mealSlots: mealSlots, collections: collections, minutes: minutes, servings: servings,
      equipment: equipment, lines: lines, steps: steps, claims: claims, nutrition: nutrition,
      rights: rights, keywords: keywords, legacyRecipeId: nil)
  }
}

// MARK: - Bundle decode

/// Fail-closed decode errors. Every per-recipe failure names the recipe id it happened in.
public enum RecipeBundleV2Error: Error, Equatable, Sendable, CustomStringConvertible {
  case malformedBundle(reason: String)
  case unsupportedSchemaVersion(found: String)
  case unsupportedBundleVersion(found: Int)
  case malformedRecipe(catalogId: String, underlying: String)
  case invalidRecipe(catalogId: String, reason: String)
  case duplicateIngredientKey(String)
  case duplicateCatalogId(String)

  public var description: String {
    switch self {
    case .malformedBundle(let reason):
      return "recipe bundle v2 is malformed: \(reason)"
    case .unsupportedSchemaVersion(let found):
      return "recipe bundle v2 has unsupported schema URL: \(found)"
    case .unsupportedBundleVersion(let found):
      return "recipe bundle v2 has unsupported bundle_version: \(found)"
    case .malformedRecipe(let catalogId, let underlying):
      return "recipe \(catalogId) is malformed: \(underlying)"
    case .invalidRecipe(let catalogId, let reason):
      return "recipe \(catalogId) is invalid: \(reason)"
    case .duplicateIngredientKey(let key):
      return "recipe bundle v2 has duplicate ingredient key: \(key)"
    case .duplicateCatalogId(let catalogId):
      return "recipe bundle v2 has duplicate catalog_id: \(catalogId)"
    }
  }
}

/// The shipped, versioned recipe bundle (`bundle_version: 2`), decoded fail-closed
/// per docs/spec/recipes/contracts/recipe-bundle-v2.schema.json.
public struct RecipeBundleV2: Equatable, Sendable {
  public static let schemaURL = "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json"
  public static let bundleVersion = 2

  public let generatedAt: String
  public let cuisines: [RecipeCatalogCuisine]
  public let ingredients: [RecipeCatalogIngredient]
  public let recipes: [RecipeBundleRecipe]

  public init(
    generatedAt: String, cuisines: [RecipeCatalogCuisine],
    ingredients: [RecipeCatalogIngredient], recipes: [RecipeBundleRecipe]
  ) {
    self.generatedAt = generatedAt
    self.cuisines = cuisines
    self.ingredients = ingredients
    self.recipes = recipes
  }

  private struct TopLevel: Decodable {
    let schema: String
    let bundleVersion: Int
    let generatedAt: String
    let cuisines: [RecipeCatalogCuisine]
    let ingredients: [RecipeCatalogIngredient]

    private enum CodingKeys: String, CodingKey {
      case schema
      case bundleVersion = "bundle_version"
      case generatedAt = "generated_at"
      case cuisines, ingredients
    }
  }

  private static let ingredientKeyPattern =
    try! NSRegularExpression(pattern: "^[a-z0-9]+(_[a-z0-9]+)*$")
  private static let catalogIdPattern =
    try! NSRegularExpression(pattern: "^rcp-[0-9]{6}$")

  /// Decodes and validates a bundle. Malformed recipes fail loudly with the recipe id.
  public static func decode(from data: Data) throws -> RecipeBundleV2 {
    let decoder = JSONDecoder()
    let top: TopLevel
    do {
      top = try decoder.decode(TopLevel.self, from: data)
    } catch {
      throw RecipeBundleV2Error.malformedBundle(reason: String(describing: error))
    }
    guard top.schema == schemaURL else {
      throw RecipeBundleV2Error.unsupportedSchemaVersion(found: top.schema)
    }
    guard top.bundleVersion == bundleVersion else {
      throw RecipeBundleV2Error.unsupportedBundleVersion(found: top.bundleVersion)
    }

    // Decode each recipe individually so a malformed one can be named by its catalog id.
    let jsonObject = try? JSONSerialization.jsonObject(with: data)
    guard let rawRecipes = (jsonObject as? [String: Any])?["recipes"] as? [[String: Any]] else {
      throw RecipeBundleV2Error.malformedBundle(reason: "recipes is not an array of objects")
    }

    var recipes: [RecipeBundleRecipe] = []
    for (index, raw) in rawRecipes.enumerated() {
      let idHint = (raw["catalog_id"] as? String) ?? "at index \(index)"
      let elementData: Data
      do {
        elementData = try JSONSerialization.data(withJSONObject: raw)
      } catch {
        throw RecipeBundleV2Error.malformedRecipe(catalogId: idHint, underlying: String(describing: error))
      }
      do {
        recipes.append(try decoder.decode(RecipeBundleRecipe.self, from: elementData))
      } catch {
        throw RecipeBundleV2Error.malformedRecipe(catalogId: idHint, underlying: String(describing: error))
      }
    }

    let bundle = RecipeBundleV2(
      generatedAt: top.generatedAt, cuisines: top.cuisines,
      ingredients: top.ingredients, recipes: recipes)
    try bundle.validate()
    return bundle
  }

  /// Fail-closed semantic checks that mirror the schema's cross-field rules.
  public func validate() throws {
    var seenKeys = Set<String>()
    for ingredient in ingredients {
      guard Self.matches(Self.ingredientKeyPattern, ingredient.key) else {
        throw RecipeBundleV2Error.invalidRecipe(
          catalogId: ingredient.key, reason: "ingredient key is not a canonical slug")
      }
      guard seenKeys.insert(ingredient.key).inserted else {
        throw RecipeBundleV2Error.duplicateIngredientKey(ingredient.key)
      }
    }

    var seenIds = Set<String>()
    for recipe in recipes {
      guard Self.matches(Self.catalogIdPattern, recipe.catalogId) else {
        throw RecipeBundleV2Error.invalidRecipe(
          catalogId: recipe.catalogId, reason: "catalog_id is not rcp-NNNNNN")
      }
      guard seenIds.insert(recipe.catalogId).inserted else {
        throw RecipeBundleV2Error.duplicateCatalogId(recipe.catalogId)
      }
      guard recipe.revision >= 1 else {
        throw RecipeBundleV2Error.invalidRecipe(
          catalogId: recipe.catalogId, reason: "revision must be >= 1")
      }
      guard recipe.lines.count >= 2, recipe.steps.count >= 2 else {
        throw RecipeBundleV2Error.invalidRecipe(
          catalogId: recipe.catalogId,
          reason: "schema requires at least 2 ingredient lines and 2 steps")
      }
      for line in recipe.lines where !seenKeys.contains(line.key) {
        throw RecipeBundleV2Error.invalidRecipe(
          catalogId: recipe.catalogId,
          reason: "ingredient line references unknown key '\(line.key)'")
      }
      for step in recipe.steps {
        for used in step.uses where used >= recipe.lines.count {
          throw RecipeBundleV2Error.invalidRecipe(
            catalogId: recipe.catalogId,
            reason: "step references ingredient index \(used) of \(recipe.lines.count) lines")
        }
      }
      for step in recipe.steps where let thermometer = step.thermometer {
        guard thermometer.source.hasPrefix("usda-fsis") else {
          throw RecipeBundleV2Error.invalidRecipe(
            catalogId: recipe.catalogId,
            reason: "thermometer source is not usda-fsis-pinned: '\(thermometer.source)'")
        }
      }
    }
  }

  private static func matches(_ pattern: NSRegularExpression, _ string: String) -> Bool {
    let range = NSRange(string.startIndex..., in: string)
    return pattern.firstMatch(in: string, range: range) != nil
  }
}

