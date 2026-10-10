import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// Tests for the shared allergen exclusion contract: explicit group selection, the
/// legacy-profile reconfirmation gate, the bundled core ingredient membership table,
/// and the v19 migration that stores group intent explicitly.
final class AllergenExclusionPolicyTests: XCTestCase {
  // MARK: - Reconfirmation gate

  func testLegacyProfilesNeedGroupConfirmation() {
    XCTAssertTrue(
      AllergenExclusions.needsGroupConfirmation(preferencesVersion: 0),
      "Version 0 (legacy rows) must be asked to reconfirm — their group state is unknown.")
    XCTAssertFalse(
      AllergenExclusions.needsGroupConfirmation(preferencesVersion: 1),
      "The current version means groups were explicitly confirmed.")
    XCTAssertFalse(AllergenExclusions.needsGroupConfirmation(preferencesVersion: 2))
  }

  // MARK: - Group ID normalization

  func testNormalizedGroupIDSDropsUnknownAndCaseDifferences() {
    let normalized = AllergenExclusions.normalizedGroupIDs(
      from: ["Milk", "  tree_nut ", "wheat_gluten", "not-a-group", ""])
    XCTAssertEqual(
      normalized, [.milk, .treeNut, .gluten],
      "Known IDs survive trimming/casing; unknown and empty strings are dropped, never guessed.")
  }

  func testAllergenSupportGroupIDsAreCanonical() {
    // The persisted group strings come from AllergenSupport.groups; if that list drifts
    // from the canonical raw values, user selections would be silently dropped on load.
    XCTAssertEqual(
      Set(AllergenSupport.groups.map(\.id)),
      Set(AllergenGroupID.allCases.map(\.rawValue)))
  }

  // MARK: - Effective exclusions

  func testNoSelectionMeansNoCoreExclusions() {
    XCTAssertTrue(AllergenExclusions.coreIngredientIDs(excludedByGroups: []).isEmpty)
    XCTAssertTrue(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["not-a-group"]).isEmpty,
      "Unrecognized group identifiers contribute nothing.")
  }

  func testEffectiveExclusionsUnionGroupsAndIndividualIDs() {
    let effective = AllergenExclusions.effectiveExcludedIngredientIDs(
      selectedGroups: ["egg"], individualExclusions: [15, 2])
    // Egg group excludes only bundled ID 1; bread (15) and rice (2) are individual picks.
    XCTAssertEqual(effective, [1, 15, 2])
  }

  func testGlutenGroupExcludesWheatStaplesButNotRiceOrCorn() {
    let excluded = AllergenExclusions.coreIngredientIDs(excludedByGroups: ["wheat_gluten"])
    XCTAssertTrue(excluded.isSuperset(of: [3, 9, 15, 28, 31]),
                  "Soy sauce (brewed with wheat), pasta, bread, tortilla, and oats are excluded.")
    XCTAssertFalse(excluded.contains(2), "Rice is not a gluten cereal.")
    XCTAssertFalse(excluded.contains(34), "Corn is not an EU Annex II gluten cereal.")
    XCTAssertFalse(excluded.contains(35), "Chickpea is not a gluten cereal.")
  }

  func testSoySauceBelongsToSoyAndGluten() {
    XCTAssertEqual(
      AllergenExclusions.memberships(forCoreIngredientID: 3), [.soy, .gluten],
      "Wheat-brewed soy sauce is declared as both soybean and a gluten cereal.")
  }

  func testPeanutButterIsPeanutOnly() {
    XCTAssertEqual(AllergenExclusions.memberships(forCoreIngredientID: 41), [.peanut])
    XCTAssertFalse(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["tree_nut"]).contains(41),
      "Peanut is a legume, not a tree nut; Tree Nuts alone must not exclude it.")
  }

  func testMilkGroupExcludesDairyCoreIngredients() {
    let excluded = AllergenExclusions.coreIngredientIDs(excludedByGroups: ["milk"])
    XCTAssertEqual(excluded, [12, 13, 14, 32, 50],
                   "Cheese, milk, butter, yogurt, and sour cream are the bundled dairy.")
  }

  func testSingleGroupSelections() {
    XCTAssertEqual(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["sesame"]), [22])
    XCTAssertEqual(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["fish"]),
      [36, 43], "Salmon and canned tuna.")
    XCTAssertEqual(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["tree_nut"]), [49],
      "Only coconut milk (FDA treats coconut as a tree nut).")
    XCTAssertEqual(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["egg"]), [1])
    XCTAssertTrue(
      AllergenExclusions.coreIngredientIDs(excludedByGroups: ["shellfish"]).isEmpty,
      "No bundled core ingredient is shellfish; the group still exists for USDA-catalog picks.")
  }

  // MARK: - Membership table integrity

  func testMembershipTableCoversExactlyTheBundledCoreIngredients() {
    let ids = Set(AllergenExclusions.coreMemberships.map(\.ingredientID))
    XCTAssertEqual(ids, Set(1...50),
                   "The table must be exhaustive over the 50 bundled core ingredients.")
    for membership in AllergenExclusions.coreMemberships {
      XCTAssertFalse(membership.basis.isEmpty, "ID \(membership.ingredientID) needs a basis.")
      for group in membership.groups {
        XCTAssertTrue(AllergenGroupID.allCases.contains(group))
      }
    }
  }

  // MARK: - HealthProfile wiring

  func testHealthProfileEffectiveExclusionsAndReconfirmationFlag() {
    let profile = HealthProfile(
      displayName: "Test", age: 30, goal: .general, dailyCalories: 2000,
      proteinPct: 0.25, carbsPct: 0.45, fatPct: 0.30,
      dietaryRestrictions: "[]",
      allergenIngredientIds: "[15,2]",
      allergenSelectedGroups: "[\"tree_nut\",\"Milk\",\"junk\"]",
      allergenPreferencesVersion: 0
    )

    XCTAssertTrue(profile.allergenNeedsGroupConfirmation)
    XCTAssertEqual(
      profile.parsedAllergenSelectedGroups,
      ["tree_nut", "milk"],
      "Normalization filters case and junk before groups are used.")
    XCTAssertEqual(
      profile.effectiveAllergenExclusionIds,
      [49, 12, 13, 14, 32, 50, 15, 2],
      "Tree Nuts + Milk group members, plus the individual picks (bread, rice).")
  }

  func testConfirmedLegacyFreeProfileHasNoImplicitExclusions() {
    // An empty selection with an explicit confirmation is a real "no groups" state —
    // and it must still exclude nothing beyond individual picks.
    let profile = HealthProfile(
      displayName: "Test", age: 30, goal: .general, dailyCalories: 2000,
      proteinPct: 0.25, carbsPct: 0.45, fatPct: 0.30,
      dietaryRestrictions: "[]",
      allergenIngredientIds: "[]",
      allergenSelectedGroups: "[]",
      allergenPreferencesVersion: AllergenExclusions.currentPreferencesVersion
    )

    XCTAssertFalse(profile.allergenNeedsGroupConfirmation)
    XCTAssertTrue(profile.effectiveAllergenExclusionIds.isEmpty)
  }

  // MARK: - v19 migration

  func testV19UpgradeAddsExplicitGroupColumnsWithSafeDefaults() throws {
    let db = try DatabaseQueue()

    // migrate() takes a DatabaseQueue, not the Database inside a write
    // closure (inherited from the base branch; minimal scope fix).
    try DatabaseMigrations.migrate(db, upTo: "v18_cooking_history_swaps")
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO health_profile (
            id, goal, daily_calories, protein_pct, carbs_pct, fat_pct,
            dietary_restrictions, allergen_ingredient_ids, updated_at
          ) VALUES (1, 'general', 2000, 0.25, 0.45, 0.30, '[]', '[15]', CURRENT_TIMESTAMP)
          """)
    }

    try DatabaseMigrations.migrate(db)

    try db.read { db in
      let groups = try String.fetchOne(
        db, sql: "SELECT allergen_selected_groups FROM health_profile WHERE id = 1")
      XCTAssertEqual(
        groups, "[]",
        "No backfill: a legacy row's group intent stays empty, never reconstructed.")

      let version = try Int.fetchOne(
        db, sql: "SELECT allergen_preferences_version FROM health_profile WHERE id = 1")
      XCTAssertEqual(version, 0, "Legacy rows keep version 0 so they are asked to reconfirm.")

      let exclusions = try String.fetchOne(
        db, sql: "SELECT allergen_ingredient_ids FROM health_profile WHERE id = 1")
      XCTAssertEqual(exclusions, "[15]", "Individual exclusions survive the migration untouched.")
    }
  }
}
