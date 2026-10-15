import Foundation

// MARK: - Canonical allergen group IDs

/// Canonical identifiers for the allergen groups a user can explicitly select.
/// The raw values are the persisted strings (JSON in `health_profile.allergen_selected_groups`)
/// and must stay in sync with `AllergenSupport.groups` in
/// `Feature/Onboarding/AllergenSupport.swift`, which renders the group chips.
enum AllergenGroupID: String, CaseIterable, Sendable {
  case milk
  case egg
  case peanut
  case treeNut = "tree_nut"
  case gluten = "wheat_gluten"
  case soy
  case fish
  case shellfish
  case sesame
  case mustard
}

// MARK: - Preferences version

/// Version of the explicit allergen preferences state.
///
/// `0` means "never explicitly reviewed": every profile written before explicit group
/// selection existed lands here after migration, and the app asks those profiles to
/// reconfirm their allergen groups instead of presenting their exclusions as complete.
/// A profile that completed onboarding, or reconfirmed in Settings, stores
/// `AllergenExclusions.currentPreferencesVersion`.
/// Shared, Foundation-only source of truth for which bundled core ingredients each
/// allergen group excludes, and for computing a profile's effective exclusion set.
///
/// This is the contract RecipeRepository consumes today. Recipe generation and ingredient
/// swaps should call the same functions rather than re-deriving exclusions from
/// `allergen_ingredient_ids` — group intent lives only in the explicitly selected group
/// identifiers and is never reconstructed from saved ingredient IDs.
///
/// Scope (deliberate, conservative): the membership table covers the 50 bundled core
/// ingredients, where the recipe catalog's own IDs are stable and the basis is citable.
/// Keyword matches in the wider USDA catalog are UI suggestions, not verified package
/// allergen data, and are never promoted into automatic exclusions here. There is no
/// blanket allergy-safety guarantee: a selected group removes the core ingredients
/// listed below plus the user's individually excluded ingredients, and nothing else.
enum AllergenExclusions {
  /// The version written whenever the user explicitly confirms allergen groups
  /// (including confirming "no groups").
  static let currentPreferencesVersion = 1

  /// Legacy profiles (version 0) have no explicit group choice on record. Their group
  /// state is unknown — never inferred, never treated as "no allergies".
  static func needsGroupConfirmation(preferencesVersion: Int) -> Bool {
    preferencesVersion < currentPreferencesVersion
  }

// MARK: - Bundled core ingredient membership

/// One row of the curated membership table for the 50 bundled core ingredients
/// (`apps/ios/Resources/data.json`, IDs 1–50). `groups` lists every selected group that
/// excludes the ingredient; the table is multi-group on purpose (e.g. wheat-brewed soy
/// sauce is both Soy and Gluten).
///
/// Primary basis:
/// - FDA: FALCPA (Public Law 108-282) and the FASTER Act (Public Law 117-89) — major
///   allergens are milk, eggs, fish, crustacean shellfish, tree nuts, peanuts, wheat,
///   soybeans, and sesame; labeling rules at 21 CFR 101.4 and the FDA FALCPA
///   Questions & Answers guidance (which treats coconut as a tree nut).
/// - EU: Regulation (EU) No 1169/2011 Annex II — cereals containing gluten (wheat, rye,
///   barley, oats, spelt), crustaceans, eggs, fish, peanuts, soybeans, milk, tree nuts,
///   celery, mustard, sesame, lupin, molluscs, sulphites.
/// - EU: Regulation (EU) No 828/2014 — "gluten-free" claims threshold and the
///   requirement that oats be specially produced to avoid cross-contact.
struct CoreIngredientAllergenMembership: Sendable {
  let ingredientID: Int64
  /// Ingredient name as bundled in `apps/ios/Resources/data.json` — kept beside the ID
  /// so a catalog change trips a test instead of silently mismatching memberships.
  let bundledName: String
  let groups: Set<AllergenGroupID>
  /// Why the membership (or its absence) is what it is.
  let basis: String
}

  /// The curated table for all 50 bundled core ingredients. Safe ingredients are listed
  /// with an empty `groups` so the set is exhaustive and auditable.
  static let coreMemberships: [CoreIngredientAllergenMembership] = [
    .init(ingredientID: 1, bundledName: "egg", groups: [.egg],
          basis: "FDA FALCPA major allergen (eggs); EU 1169/2011 Annex II (eggs)."),
    .init(ingredientID: 2, bundledName: "rice", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Traditionally brewed soy sauce is fermented from soybeans and wheat: the FDA
    // requires declaring soy (and the wheat), and EU Annex II requires declaring both
    // the soybean and the gluten-containing cereal. Treated as both groups.
    .init(ingredientID: 3, bundledName: "soy_sauce", groups: [.soy, .gluten],
          basis: "FDA FALCPA (soybeans; brewed with wheat, so wheat is declared); EU 1169/2011 Annex II (soybeans; cereals containing gluten)."),
    .init(ingredientID: 4, bundledName: "chicken_breast", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 5, bundledName: "onion", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Garlic allergy is reported but garlic is in neither the FDA major-allergen list
    // nor EU Annex II, so no group excludes it.
    .init(ingredientID: 6, bundledName: "garlic", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 7, bundledName: "tomato", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 8, bundledName: "bell_pepper", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Ordinary pasta is durum wheat semolina; conservative packaged-food assumption.
    .init(ingredientID: 9, bundledName: "pasta", groups: [.gluten],
          basis: "EU 1169/2011 Annex II (wheat — cereals containing gluten); FDA FALCPA (wheat)."),
    .init(ingredientID: 10, bundledName: "potato", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 11, bundledName: "carrot", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 12, bundledName: "cheese", groups: [.milk],
          basis: "FDA FALCPA major allergen (milk); EU 1169/2011 Annex II (milk)."),
    .init(ingredientID: 13, bundledName: "milk", groups: [.milk],
          basis: "FDA FALCPA major allergen (milk); EU 1169/2011 Annex II (milk)."),
    // "Butter" as a packaged core ingredient means dairy butter; the allergen system's
    // Milk group excludes it. (Nut butters are matched separately by keyword in the
    // picker UI; peanut butter is Peanut only.)
    .init(ingredientID: 14, bundledName: "butter", groups: [.milk],
          basis: "FDA FALCPA major allergen (milk); EU 1169/2011 Annex II (milk)."),
    // Ordinary packaged bread is wheat flour; conservative assumption.
    .init(ingredientID: 15, bundledName: "bread", groups: [.gluten],
          basis: "EU 1169/2011 Annex II (wheat — cereals containing gluten); FDA FALCPA (wheat)."),
    .init(ingredientID: 16, bundledName: "olive_oil", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 17, bundledName: "lemon", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 18, bundledName: "mushroom", groups: [],
          basis: "Not an FDA or EU Annex II allergen (molluscs do not cover fungi)."),
    .init(ingredientID: 19, bundledName: "spinach", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 20, bundledName: "banana", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 21, bundledName: "green_onion", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 22, bundledName: "sesame_oil", groups: [.sesame],
          basis: "FDA FASTER Act — sesame a major allergen effective 2023; EU 1169/2011 Annex II (sesame)."),
    .init(ingredientID: 23, bundledName: "tofu", groups: [.soy],
          basis: "FDA FALCPA major allergen (soybeans); EU 1169/2011 Annex II (soybeans)."),
    .init(ingredientID: 24, bundledName: "broccoli", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 25, bundledName: "cucumber", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 26, bundledName: "avocado", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 27, bundledName: "black_beans", groups: [],
          basis: "Legume, but not soybeans or peanuts — not an FDA or EU Annex II allergen."),
    // Unqualified "tortilla" is conservatively treated as the ordinary wheat-flour
    // tortilla, not a corn tortilla.
    .init(ingredientID: 28, bundledName: "tortilla", groups: [.gluten],
          basis: "EU 1169/2011 Annex II (wheat — cereals containing gluten); FDA FALCPA (wheat)."),
    .init(ingredientID: 29, bundledName: "lime", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 30, bundledName: "ginger", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Conservative packaged-food assumption: conventional oats commonly carry
    // wheat/barley cross-contact, and EU 828/2014 only permits "gluten-free" oat
    // products that are specially produced below the 20 mg/kg threshold. A user who
    // selects Gluten is excluding oats until a certified-GF choice is made.
    .init(ingredientID: 31, bundledName: "oats", groups: [.gluten],
          basis: "EU 828/2014 (oats must be specially produced for gluten-free claims; conventional oats risk cross-contact); FDA treats oats as a gluten-free grain but does not certify cross-contact."),
    .init(ingredientID: 32, bundledName: "yogurt", groups: [.milk],
          basis: "FDA FALCPA major allergen (milk); EU 1169/2011 Annex II (milk)."),
    .init(ingredientID: 33, bundledName: "honey", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 34, bundledName: "corn", groups: [],
          basis: "Not an FDA or EU Annex II allergen (maize is not an EU gluten cereal)."),
    .init(ingredientID: 35, bundledName: "chickpea", groups: [],
          basis: "Legume, but not soybeans or peanuts — not an FDA or EU Annex II allergen."),
    .init(ingredientID: 36, bundledName: "salmon", groups: [.fish],
          basis: "FDA FALCPA major allergen (fin fish); EU 1169/2011 Annex II (fish)."),
    .init(ingredientID: 37, bundledName: "sweet_potato", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 38, bundledName: "ground_beef", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 39, bundledName: "lettuce", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 40, bundledName: "apple", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Peanut is a legume: peanut butter is Peanut ONLY. It is not a tree nut under
    // either the FDA major-allergen list or EU Annex II, so selecting Tree Nuts alone
    // does not exclude it.
    .init(ingredientID: 41, bundledName: "peanut_butter", groups: [.peanut],
          basis: "FDA FALCPA major allergen (peanuts); EU 1169/2011 Annex II (peanuts). Not a tree nut."),
    .init(ingredientID: 42, bundledName: "frozen_peas", groups: [],
          basis: "Legume, but not soybeans or peanuts — not an FDA or EU Annex II allergen."),
    .init(ingredientID: 43, bundledName: "canned_tuna", groups: [.fish],
          basis: "FDA FALCPA major allergen (fin fish); EU 1169/2011 Annex II (fish)."),
    .init(ingredientID: 44, bundledName: "celery", groups: [],
          basis: "EU 1169/2011 Annex II allergen, but the app defines no Celery group, so no selectable group excludes it."),
    .init(ingredientID: 45, bundledName: "zucchini", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 46, bundledName: "red_pepper_flakes", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 47, bundledName: "cumin", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    .init(ingredientID: 48, bundledName: "cilantro", groups: [],
          basis: "Not an FDA or EU Annex II allergen."),
    // Conservative, FDA-labeling basis: the FDA's FALCPA guidance treats coconut as a
    // tree nut for labeling, even though botanically it is a fruit and EU Annex II does
    // not list it. Selecting Tree Nuts excludes coconut milk.
    .init(ingredientID: 49, bundledName: "coconut_milk", groups: [.treeNut],
          basis: "FDA FALCPA Questions & Answers (coconut treated as a tree nut for labeling). Not listed in EU 1169/2011 Annex II; kept in Tree Nuts conservatively."),
    .init(ingredientID: 50, bundledName: "sour_cream", groups: [.milk],
          basis: "FDA FALCPA major allergen (milk); EU 1169/2011 Annex II (milk)."),
  ]

  /// Membership lookup for one bundled core ingredient ID. Unknown IDs (anything outside
  /// the bundled 1–50, e.g. USDA catalog rows) return an empty set: the curated table
  /// makes no claims about them.
  static func memberships(forCoreIngredientID ingredientID: Int64) -> Set<AllergenGroupID> {
    coreMembershipByID[ingredientID]?.groups ?? []
  }

  private static let coreMembershipByID: [Int64: CoreIngredientAllergenMembership] = {
    Dictionary(uniqueKeysWithValues: coreMemberships.map { ($0.ingredientID, $0) })
  }()
}

// MARK: - Effective exclusion computation

extension AllergenExclusions {
  /// The set of bundled core ingredient IDs excluded by the explicitly selected groups.
  /// Accepts raw persisted strings; unrecognized group identifiers contribute nothing
  /// (they cannot be honored, and they must not be guessed at).
  static func coreIngredientIDs(excludedByGroups selectedGroups: Set<String>) -> Set<Int64> {
    let groupIDs = normalizedGroupIDs(from: selectedGroups)
    guard !groupIDs.isEmpty else { return [] }

    var excluded: Set<Int64> = []
    for membership in coreMemberships where !membership.groups.isDisjoint(with: groupIDs) {
      excluded.insert(membership.ingredientID)
    }
    return excluded
  }

  /// The profile's effective allergen exclusion set: members of the explicitly selected
  /// groups UNION the individually excluded ingredient IDs. Group intent is never
  /// reconstructed from the individual IDs, and individual IDs never widen a group.
  static func effectiveExcludedIngredientIDs(
    selectedGroups: Set<String>,
    individualExclusions: Set<Int64>
  ) -> Set<Int64> {
    coreIngredientIDs(excludedByGroups: selectedGroups).union(individualExclusions)
  }

  /// Filters raw persisted group identifiers down to canonical ones
  /// (trimmed, lowercased, known). Unknown strings are dropped, not guessed.
  static func normalizedGroupIDs(from rawGroups: Set<String>) -> Set<AllergenGroupID> {
    var normalized: Set<AllergenGroupID> = []
    for raw in rawGroups {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if let group = AllergenGroupID(rawValue: trimmed) {
        normalized.insert(group)
      }
    }
    return normalized
  }
}
