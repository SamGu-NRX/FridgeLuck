import Foundation
import XCTest

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Fail-closed contract for the stored allergen group preferences
/// (`health_profile.allergen_selected_groups`).
///
/// A profile whose stored selection cannot be fully read — malformed JSON, or any
/// string that is not a canonical group identifier — must never evaluate to "no
/// restrictions": enforcement excludes the entire curated core universe until the
/// profile reconfirms. Valid, well-formed selections (including the confirmed
/// "no groups" choice) keep behaving exactly as before.
final class AllergenPreferenceFailClosedTests: XCTestCase {
  // MARK: - Fixtures

  private var allCoreIngredientIds: Set<Int64> {
    Set(AllergenExclusions.coreMemberships.map(\.ingredientID))
  }

  private func makeProfile(
    allergenSelectedGroups: String,
    allergenIngredientIds: String = "[]",
    version: Int = AllergenExclusions.currentPreferencesVersion
  ) -> HealthProfile {
    HealthProfile(
      displayName: "Test", age: 30, goal: .general, dailyCalories: 2000,
      proteinPct: 0.25, carbsPct: 0.45, fatPct: 0.30,
      dietaryRestrictions: "[]",
      allergenIngredientIds: allergenIngredientIds,
      allergenSelectedGroups: allergenSelectedGroups,
      allergenPreferencesVersion: version
    )
  }

  // MARK: - Valid selections keep the previous behavior

  func testValidSelectionFiltersExactlyAsBefore() {
    // Case/whitespace normalization is still honored for known identifiers.
    let profile = makeProfile(
      allergenSelectedGroups: "[ \"Milk\" , \"tree_nut\" ]",
      allergenIngredientIds: "[15,2]"
    )

    XCTAssertEqual(
      profile.parsedAllergenSelectedGroups, ["tree_nut", "milk"],
      "Known identifiers survive trimming/casing exactly as before.")
    XCTAssertEqual(
      profile.effectiveAllergenExclusionIds,
      [49, 12, 13, 14, 32, 50, 15, 2],
      "Tree Nuts + Milk group members plus the individual picks (bread, rice) — unchanged semantics.")
    XCTAssertFalse(profile.allergenNeedsGroupConfirmation)
  }

  func testConfirmedNoGroupsSelectionStaysUnrestricted() {
    let profile = makeProfile(allergenSelectedGroups: "[]")

    XCTAssertTrue(profile.parsedAllergenSelectedGroups.isEmpty)
    XCTAssertTrue(
      profile.effectiveAllergenExclusionIds.isEmpty,
      "A confirmed \"no groups\" choice is valid and excludes nothing.")
    XCTAssertFalse(profile.allergenNeedsGroupConfirmation)
  }

  // MARK: - Malformed input fails closed

  func testMalformedSelectionJSONFailsClosed() {
    let malformedSelections = [
      "[\"milk\"",  // truncated JSON
      "not json",  // not JSON at all
      "['milk']",  // single quotes are not JSON
      "[1,2]",  // non-string elements
      "null",  // JSON null
      "",  // empty storage
    ]

    for selection in malformedSelections {
      let profile = makeProfile(
        allergenSelectedGroups: selection,
        allergenIngredientIds: "[7]"
      )

      XCTAssertEqual(
        profile.effectiveAllergenExclusionIds,
        allCoreIngredientIds.union([7]),
        "'\(selection)' is unparseable — every curated core ingredient must be excluded (plus individual picks), never none.")
      XCTAssertTrue(
        profile.parsedAllergenSelectedGroups.isEmpty,
        "An untrusted selection must not prefill the group picker.")
      XCTAssertTrue(
        profile.allergenNeedsGroupConfirmation,
        "An unparseable selection must send the profile back to reconfirmation.")
    }
  }

  // MARK: - Unknown allergen identifiers fail closed

  func testUnknownGroupIdentifierFailsClosed() {
    let profile = makeProfile(allergenSelectedGroups: "[\"lupin\"]")

    XCTAssertEqual(
      profile.effectiveAllergenExclusionIds, allCoreIngredientIds,
      "An identifier the app cannot honor must exclude the curated universe, not nothing.")
    XCTAssertTrue(profile.allergenNeedsGroupConfirmation)
  }

  func testUnknownIdentifierAmongValidOnesFailsClosed() {
    // One unreadable identifier poisons the whole selection: honoring the readable
    // subset would present the exclusions as complete when they are not.
    let profile = makeProfile(
      allergenSelectedGroups: "[\"tree_nut\",\"Milk\",\"junk\"]",
      allergenIngredientIds: "[15,2]"
    )

    XCTAssertEqual(
      profile.effectiveAllergenExclusionIds, allCoreIngredientIds.union([15, 2]))
    XCTAssertTrue(profile.parsedAllergenSelectedGroups.isEmpty)
    XCTAssertTrue(profile.allergenNeedsGroupConfirmation)
  }

  func testEmptyStringElementFailsClosed() {
    let profile = makeProfile(allergenSelectedGroups: "[\"\"]")

    XCTAssertEqual(
      profile.effectiveAllergenExclusionIds, allCoreIngredientIds,
      "An empty string is not a canonical group; the selection is unreadable.")
  }

  func testUnreadableSelectionExcludesExactlyTheCuratedUniverse() {
    // The curated table covers exactly the bundled 1–50 IDs; fail-closed enforcement
    // excludes that universe in full and invents no IDs beyond it.
    XCTAssertEqual(
      AllergenExclusions.failClosedExcludedCoreIngredientIDs(from: .unreadable),
      Set(1...50))
    XCTAssertEqual(allCoreIngredientIds, Set(1...50))
  }

  // MARK: - Policy layer

  func testEvaluateGroupSelectionClassifiesStoredJSON() {
    XCTAssertEqual(
      AllergenExclusions.evaluateGroupSelection("[ \"Milk\" , \"tree_nut\" ]"),
      .valid(groups: [.milk, .treeNut]))
    XCTAssertEqual(
      AllergenExclusions.evaluateGroupSelection("[]"),
      .valid(groups: []),
      "A confirmed empty selection is valid, not unreadable.")
    XCTAssertEqual(
      AllergenExclusions.evaluateGroupSelection("not json"), .unreadable)
    XCTAssertEqual(
      AllergenExclusions.evaluateGroupSelection("[\"lupin\"]"), .unreadable)
  }

  func testEffectiveExclusionsUnionFailClosedGroupsAndIndividualIDs() {
    XCTAssertEqual(
      AllergenExclusions.effectiveExcludedIngredientIDs(
        evaluation: .valid(groups: [.egg]),
        individualExclusions: [15, 2]),
      [1, 15, 2],
      "Valid groups keep the exact previous union semantics.")

    XCTAssertEqual(
      AllergenExclusions.effectiveExcludedIngredientIDs(
        evaluation: .unreadable,
        individualExclusions: [15, 2]),
      allCoreIngredientIds.union([15, 2]),
      "Unreadable group intent fails closed while individual picks still apply.")
  }

  // MARK: - Reconfirmation gate stays version-driven for valid state

  func testLegacyVersionStillNeedsConfirmationForValidSelections() {
    let legacy = makeProfile(allergenSelectedGroups: "[]", version: 0)
    XCTAssertTrue(legacy.allergenNeedsGroupConfirmation)

    let confirmed = makeProfile(
      allergenSelectedGroups: "[\"milk\"]",
      version: AllergenExclusions.currentPreferencesVersion)
    XCTAssertFalse(confirmed.allergenNeedsGroupConfirmation)
  }
}
