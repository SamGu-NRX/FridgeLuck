import XCTest
@testable import ProfileBasicsCheck

/// Literal-control unit tests for the pure core: age parsing, validation,
/// and commit mapping. Every input is a fixed literal and every expectation is
/// asserted with equality against a constructed literal — no floats printed,
/// no profile values in messages.
final class ProfileBasicsCoreParseTests: XCTestCase {

  // MARK: - parseAge

  func testParseAgeBlankStringIsBlankOptional() {
    let parseOutcome = ProfileBasicsCore.parseAge("")
    XCTAssertTrue(parseOutcome == .blankOptional, "empty age text must parse as blankOptional")
  }

  func testParseAgeWhitespaceOnlyStringIsBlankOptional() {
    let parseOutcome = ProfileBasicsCore.parseAge("   ")
    XCTAssertTrue(parseOutcome == .blankOptional, "whitespace-only age text must parse as blankOptional")
  }

  func testParseAgeLowerBoundIsValid() {
    let parseOutcome = ProfileBasicsCore.parseAge("13")
    XCTAssertTrue(parseOutcome == .valid(13), "the lower bound age must parse as valid")
  }

  func testParseAgeUpperBoundIsValid() {
    let parseOutcome = ProfileBasicsCore.parseAge("100")
    XCTAssertTrue(parseOutcome == .valid(100), "the upper bound age must parse as valid")
  }

  func testParseAgeMiddleValueIsValid() {
    let parseOutcome = ProfileBasicsCore.parseAge("42")
    XCTAssertTrue(parseOutcome == .valid(42), "a typical in-range age must parse as valid")
  }

  func testParseAgeNonNumericIsInvalidWithWholeNumberMessage() {
    let parseOutcome = ProfileBasicsCore.parseAge("abc")
    XCTAssertTrue(
      parseOutcome == .invalid(message: "Age must be a whole number."),
      "non-numeric age must be rejected with the whole-number message")
  }

  func testParseAgeEmbeddedSpaceIsInvalidWithWholeNumberMessage() {
    let parseOutcome = ProfileBasicsCore.parseAge("1 2")
    XCTAssertTrue(
      parseOutcome == .invalid(message: "Age must be a whole number."),
      "an age with an embedded space must be rejected with the whole-number message")
  }

  func testParseAgeBelowRangeIsInvalidWithRangeMessage() {
    let parseOutcome = ProfileBasicsCore.parseAge("12")
    XCTAssertTrue(
      parseOutcome == .invalid(message: "Age must be between 13 and 100."),
      "an age below the range must be rejected with the range message")
  }

  func testParseAgeAboveRangeIsInvalidWithRangeMessage() {
    let parseOutcome = ProfileBasicsCore.parseAge("101")
    XCTAssertTrue(
      parseOutcome == .invalid(message: "Age must be between 13 and 100."),
      "an age above the range must be rejected with the range message")
  }

  func testParseAgeOverflowIsInvalidWithWholeNumberMessage() {
    let parseOutcome = ProfileBasicsCore.parseAge("99999999999999999999")
    XCTAssertTrue(
      parseOutcome == .invalid(message: "Age must be a whole number."),
      "an overflowing age literal must be rejected with the whole-number message")
  }

  // MARK: - validate

  func testValidateOkForBlankOptionalAge() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "Synthetic User",
      ageText: "")
    assertValidationEquality(
      ProfileBasicsCore.validate(draft),
      equals: .ok)
  }

  func testValidateInvalidCarriesWholeNumberMessage() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "Synthetic User",
      ageText: "abc")
    assertValidationEquality(
      ProfileBasicsCore.validate(draft),
      equals: .invalid(message: "Age must be a whole number."))
  }

  func testValidateInvalidCarriesRangeMessage() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "Synthetic User",
      ageText: "101")
    assertValidationEquality(
      ProfileBasicsCore.validate(draft),
      equals: .invalid(message: "Age must be between 13 and 100."))
  }

  func testValidateOkForValidAge() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "Synthetic User",
      ageText: "42")
    assertValidationEquality(
      ProfileBasicsCore.validate(draft),
      equals: .ok)
  }

  // MARK: - committedProfile

  func testCommittedProfileRewritesOnlyNameAndAge() {
    let loaded = SyntheticProfile.rich()
    let draft = ProfileBasicsDraft(
      profile: loaded,
      displayNameText: "Synthetic Edited",
      ageText: "34")
    let committed = ProfileBasicsCore.committedProfile(from: draft)

    XCTAssertTrue(committed.displayName == "Synthetic Edited", "the committed display name must be the edited one")
    XCTAssertTrue(committed.age == 34, "the committed age must be the parsed age")
    XCTAssertTrue(committed.goal == .weightLoss, "the goal must carry over untouched")
    XCTAssertTrue(committed.dailyCalories == 1800, "daily calories must carry over untouched")
    XCTAssertTrue(committed.proteinPct == 0.40, "the protein pct must carry over untouched")
    XCTAssertTrue(committed.carbsPct == 0.35, "the carbs pct must carry over untouched")
    XCTAssertTrue(committed.fatPct == 0.25, "the fat pct must carry over untouched")
    XCTAssertTrue(committed.dietaryRestrictions == "[\"vegan\"]", "dietary restrictions must carry over untouched")
    XCTAssertTrue(committed.allergenIngredientIds == "[\"3\",\"7\"]", "allergen ids must carry over untouched")
    XCTAssertTrue(committed.updatedAt == SyntheticProfile.fixedUpdatedAt, "the loaded updated date must carry over untouched")
  }

  func testCommittedProfileTrimsDisplayNameWhitespace() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "  Edgy Name  ",
      ageText: "34")
    let committed = ProfileBasicsCore.committedProfile(from: draft)
    XCTAssertTrue(committed.displayName == "Edgy Name", "committed display names must be trimmed")
  }

  func testCommittedProfileBlankAgeCommitsNil() {
    let draft = ProfileBasicsDraft(
      profile: SyntheticProfile.make(age: 30),
      displayNameText: "Synthetic User",
      ageText: "   ")
    let committed = ProfileBasicsCore.committedProfile(from: draft)
    XCTAssertTrue(committed.age == nil, "a blank age must commit as nil")
  }

  func testParseAgeThenValidateAndCommitRoundTrip() {
    let loaded = SyntheticProfile.rich()
    let draft = ProfileBasicsDraft(
      profile: loaded,
      displayNameText: "Edgy Name",
      ageText: "34")
    let parseOutcome = ProfileBasicsCore.parseAge(draft.ageText)
    XCTAssertTrue(parseOutcome == .valid(34), "the round-trip age must parse as valid")
    assertValidationEquality(ProfileBasicsCore.validate(draft), equals: .ok)
    let committed = ProfileBasicsCore.committedProfile(from: draft)
    assertProfile(committed, matches: loaded)
  }
}
