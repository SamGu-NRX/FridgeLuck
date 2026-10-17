import FLFeatureLogic
import Foundation
import GRDB

/// The household safety screen for one query, read once and asked by every path that hands
/// the household a recipe or a swap: recommendations (legacy and catalog pools), the weekly
/// and guest plans, saved-plan reloads, recipe search, the catalog browse list, and every
/// substitution offer and recheck.
///
/// Before this type each path assembled its own subset of the rules. The legacy pool ran
/// only the diet tag mask and exact excluded ids, so a pescatarian household (no tag) was
/// offered legacy meat recipes; swap screens checked one bridged id per substitute key; and
/// search and saved plans screened nothing. The rules themselves live in
/// `HouseholdSafetyGate` (composition classes) and `HouseholdSafetyProfileResolver`
/// (household groups, vocabulary classes, catalog admission); this type carries their
/// inputs and applies them the same way for legacy rows, catalog rows and single
/// ingredients.
struct HouseholdSafetyBoundary: Sendable {
  let household: HouseholdSafetyProfile
  /// The profile's selected diet id ("vegan", "keto", ...), or nil.
  let dietID: String?
  /// Stored allergen ingredient ids plus the diet's excluded ingredient ids.
  let excludedIDs: Set<Int64>
  /// The diet tag a legacy recipe must carry (`HealthProfile.requiredRecipeTagMask`).
  let requiredRecipeTagMask: Int
  let classesByKey: [String: [String]]
  let bridgedIDsByKey: [String: Set<Int64>]
  let keysByIngredientID: [Int64: Set<String>]

  static func load(profile: HealthProfile, in db: Database) throws -> Self {
    var bridgedIDsByKey: [String: Set<Int64>] = [:]
    var keysByIngredientID: [Int64: Set<String>] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge")
    {
      guard let key: String = row["ingredient_key"], let id: Int64 = row["ingredient_id"]
      else { continue }
      bridgedIDsByKey[key, default: []].insert(id)
      keysByIngredientID[id, default: []].insert(key)
    }
    return Self(
      household: try HouseholdSafetyProfileResolver.householdProfile(
        allergenIds: Set(profile.parsedAllergenIds), dietID: profile.selectedDietID, in: db),
      dietID: profile.selectedDietID,
      excludedIDs: Set(profile.parsedAllergenIds).union(profile.dietaryExcludedIngredientIds),
      requiredRecipeTagMask: profile.requiredRecipeTagMask,
      classesByKey: try HouseholdSafetyProfileResolver.classesByKey(in: db),
      bridgedIDsByKey: bridgedIDsByKey,
      keysByIngredientID: keysByIngredientID)
  }

  /// The boundary for the stored household (`health_profile` row 1). A missing row is the
  /// default, unrestricted profile; a failed read throws, and callers refuse everything.
  static func loadStored(in db: Database) throws -> Self {
    try load(profile: storedScreeningProfile(in: db), in: db)
  }

  /// The stored profile's two screening columns, wrapped in a `HealthProfile` so the diet,
  /// its excluded ids and its tag mask derive exactly as they do for a passed-in profile.
  /// Only these columns are read: plan fixtures carry a reduced `health_profile` table, and
  /// decoding the full record there used to fall back to an unrestricted default.
  static func storedScreeningProfile(in db: Database) throws -> HealthProfile {
    var profile = HealthProfile.default
    if let row = try Row.fetchOne(
      db,
      sql: "SELECT allergen_ingredient_ids, dietary_restrictions FROM health_profile WHERE id = 1")
    {
      profile.allergenIngredientIds = row["allergen_ingredient_ids"] ?? "[]"
      profile.dietaryRestrictions = row["dietary_restrictions"] ?? "[]"
    }
    return profile
  }

  // MARK: - Recipes

  /// A catalog recipe, by its line keys and diet claims. The rule recommendations and the
  /// weekly plan already shared (`HouseholdSafetyProfileResolver.admitsCatalogRecipe`).
  func admitsCatalogRecipe(lineKeys: [String], claimsJSON: String?) -> Bool {
    HouseholdSafetyProfileResolver.admitsCatalogRecipe(
      household: household, dietID: dietID, lineKeys: lineKeys, claimsJSON: claimsJSON,
      classesByKey: classesByKey, bridgedIDsByKey: bridgedIDsByKey, excludedIDs: excludedIDs)
  }

  /// A legacy (`recipes` table) recipe, screened on the lines given (app ingredient ids).
  ///
  /// Order of reasons: a class conflict (allergen or diet), a flagged id, unknown
  /// composition, then the diet tag. Legacy rows carry no diet claims, only authored tags, so
  /// a diet still needs its tag (`requiredRecipeTagMask`) and the line classes must not break
  /// it. Keto is the
  /// exception: no class expresses low-carb and the catalog refuses keto outright, but a
  /// legacy row's low-carb tag is an authored claim, so for keto the tag decides and the
  /// classes are screened only for allergens. A recipe with no ingredient rows at all (a
  /// saved title with nothing behind it) is unknown composition, not an empty, safe one.
  func legacyRecipeVerdict(ingredientIDs: [Int64], tags: Int) -> HouseholdSafetyVerdict {
    var composition = household
    if composition.diet == .keto { composition.diet = nil }
    let lines =
      ingredientIDs.isEmpty ? [RecipeLineSafety.unknown] : ingredientIDs.map(lineSafety(ingredientID:))
    let screened = verdict(composition: composition, lines: lines, ingredientIDs: ingredientIDs)
    if case .blocked = screened { return screened }
    if let diet = household.diet, tags & requiredRecipeTagMask != requiredRecipeTagMask {
      return .blocked(.diet(diet))
    }
    return .allowed
  }

  /// The short reason a refused recipe carries where it is shown anyway (search), or nil
  /// when the verdict allows it. Reads the flagged ingredient's name for an id flag.
  static func warning(for verdict: HouseholdSafetyVerdict, in db: Database) throws -> String? {
    guard case .blocked(let block) = verdict else { return nil }
    switch block {
    case .allergen(let group):
      let title =
        AllergenSupport.groups.first { $0.id == group.rawValue }?.title ?? group.rawValue
      return "Contains \(title.lowercased())"
    case .diet(let diet):
      return "Doesn't fit your \(diet.rawValue) diet"
    case .unknownComposition:
      return "Can't confirm it fits your restrictions"
    case .excludedIngredient(let id):
      guard let ingredient = try Ingredient.fetchOne(db, key: id) else {
        return "Contains an ingredient you flagged"
      }
      return "Contains \(ingredient.displayName.lowercased()), which you flagged"
    }
  }

  // MARK: - Unknown composition, named

  // An unknown-composition refusal used to read "Can't confirm it fits your restrictions" with
  // no reason. Kimchi Fried Rice was refused for its kimchi line and Blueberry Diner Pancakes for
  // baking powder and sugar, all classed `unknown` in the bundle (2026-10-16 walk at alpha
  // af85600). These only name the lines; the verdict comes from the screen as before.

  /// The warning for a catalog recipe: the verdict's own reason, with an unknown-composition
  /// refusal naming the lines the screen couldn't settle.
  func warning(for verdict: HouseholdSafetyVerdict, lineKeys: [String], in db: Database) throws
    -> String?
  {
    guard case .blocked(.unknownComposition) = verdict else {
      return try Self.warning(for: verdict, in: db)
    }
    var seen = Set<String>()
    let keys = lineKeys.filter { key in
      let classes = HouseholdSafetyProfileResolver.lineSafety(key: key, classesByKey: classesByKey)
        .classes
      return (classes.isEmpty || classes.contains("unknown")) && seen.insert(key).inserted
    }
    var names: [String: String] = [:]
    if !keys.isEmpty {
      let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
      for row in try Row.fetchAll(
        db,
        sql: "SELECT key, display_name FROM recipes_catalog_ingredients WHERE key IN (\(placeholders))",
        arguments: StatementArguments(keys))
      {
        names[row["key"]] = row["display_name"]
      }
    }
    return try unknownCompositionWarning(
      names: keys.map { RecipeRepository.catalogLineName(key: $0, displayName: names[$0]) },
      in: db)
  }

  /// The warning for a legacy recipe, by its lines' app ingredient ids.
  func warning(for verdict: HouseholdSafetyVerdict, ingredientIDs: [Int64], in db: Database)
    throws -> String?
  {
    guard case .blocked(.unknownComposition) = verdict else {
      return try Self.warning(for: verdict, in: db)
    }
    var seen = Set<Int64>()
    let unknownIDs = ingredientIDs.filter { id in
      let classes = lineSafety(ingredientID: id).classes
      return (classes.isEmpty || classes.contains("unknown")) && seen.insert(id).inserted
    }
    let names = try unknownIDs.map { id in
      try Ingredient.fetchOne(db, key: id)?.displayName ?? "ingredient \(id)"
    }
    return try unknownCompositionWarning(names: names, in: db)
  }

  /// "We can't check kimchi for peanut". Falls back to the general line when no line is
  /// unknown, which happens when a catalog refusal has no other stated reason.
  private func unknownCompositionWarning(names: [String], in db: Database) throws -> String? {
    guard !names.isEmpty else { return try Self.warning(for: .blocked(.unknownComposition), in: db) }
    let lowered = names.map { $0.lowercased() }
    let lines: String
    switch lowered.count {
    case 1: lines = lowered[0]
    case 2: lines = "\(lowered[0]) and \(lowered[1])"
    default: lines = "\(lowered[0]), \(lowered[1]) and \(lowered.count - 2) more"
    }
    var restrictions = household.allergenGroups
      .map { group in
        (AllergenSupport.groups.first { $0.id == group.rawValue }?.title ?? group.rawValue)
          .lowercased()
      }
      .sorted()
    if let diet = household.diet { restrictions.append("your \(diet.rawValue) diet") }
    guard !restrictions.isEmpty else { return "We can't check \(lines) for your restrictions" }
    return "We can't check \(lines) for \(restrictions.joined(separator: " or "))"
  }

  // MARK: - Single ingredients (swaps)

  /// One ingredient on its own, the way a substitute is screened. Unlike a legacy recipe it
  /// has no tag to prove keto, so a keto household refuses every substitute, as the offer
  /// screen always has.
  func ingredientVerdict(_ ingredientID: Int64) -> HouseholdSafetyVerdict {
    verdict(
      composition: household, lines: [lineSafety(ingredientID: ingredientID)],
      ingredientIDs: [ingredientID])
  }

  /// The gate's verdict with flagged ids folded in. A class conflict keeps its allergen or
  /// diet reason; a flagged id outranks unknown composition, because the flag is certain and
  /// "unknown" is not. Swap screens keep unknown-composition swaps visible as ask-the-user
  /// rows, so a flagged substitute reported as merely unknown would stay on screen.
  private func verdict(
    composition: HouseholdSafetyProfile, lines: [RecipeLineSafety], ingredientIDs: [Int64]
  ) -> HouseholdSafetyVerdict {
    let screened = HouseholdSafetyGate.screen(household: composition, lines: lines)
    if case .blocked(let block) = screened, block != .unknownComposition { return screened }
    for ingredientID in ingredientIDs {
      if let flagged = flaggedID(matching: ingredientID) {
        return .blocked(.excludedIngredient(flagged))
      }
    }
    return screened
  }

  // MARK: - Ingredient identity

  /// An app ingredient's composition: the classes of every vocabulary key it bridges to.
  /// An ingredient with no bridge row, or a key with no classes, is unknown composition.
  func lineSafety(ingredientID: Int64) -> RecipeLineSafety {
    let keys = keysByIngredientID[ingredientID] ?? []
    guard !keys.isEmpty else { return .unknown }
    var classes = Set<String>()
    for key in keys {
      let keyClasses = HouseholdSafetyProfileResolver.lineSafety(
        key: key, classesByKey: classesByKey
      ).classes
      classes.formUnion(keyClasses.isEmpty ? RecipeLineSafety.unknown.classes : keyClasses)
    }
    return RecipeLineSafety(classes: classes)
  }

  /// The flagged id an ingredient matches: itself, or any app ingredient bridged to one of
  /// its vocabulary keys. The bridge maps one key to several ids, so checking only the id a
  /// surface happens to hold missed a flag on the key's other ids.
  func flaggedID(matching ingredientID: Int64) -> Int64? {
    guard !excludedIDs.isEmpty else { return nil }
    if excludedIDs.contains(ingredientID) { return ingredientID }
    var sameFood = Set<Int64>()
    for key in keysByIngredientID[ingredientID] ?? [] {
      sameFood.formUnion(bridgedIDsByKey[key] ?? [])
    }
    return sameFood.intersection(excludedIDs).min()
  }
}
