import XCTest
import GRDB
@testable import ProfileBasicsCheck

/// Save-path literal controls over the real flow: optional blank age, blocking
/// invalid ages, persistence of valid edits (including field preservation),
/// controlled save failure with retry, exactly-one onSaved, and reentrancy
/// guards during the save pipeline.
final class ProfileBasicsFlowSaveTests: XCTestCase {

  // MARK: - Blank age keeps optional behavior

  func testSaveWithBlankAgeStoresNilAge() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let flow = TestFlow.make(store: store, onSaved: { savedCount += 1 })
    flow.load()
    flow.setAgeText("")

    guard case .editing(_, validation: let blankValidation) = flow.phase else {
      XCTFail("expected editing phase after setting the age text")
      return
    }
    XCTAssertTrue(blankValidation == .ok, "blank age must not produce a validation error")

    flow.save()

    XCTAssertTrue(flow.phase == .saved, "blank-age save should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "a successful save should fire onSaved exactly once")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.age == nil, "a blank age must store nil age")
    XCTAssertTrue(
      refetched.displayName == seeded.displayName,
      "a blank-age save must not change the display name")
  }

  func testSaveWithWhitespaceAgeStoresNilAge() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    let flow = TestFlow.make(store: store)
    flow.load()
    flow.setAgeText("   ")

    guard case .editing(_, validation: let blankValidation) = flow.phase else {
      XCTFail("expected editing phase after setting the age text")
      return
    }
    XCTAssertTrue(blankValidation == .ok, "whitespace-only age must not produce a validation error")

    flow.save()

    XCTAssertTrue(flow.phase == .saved, "whitespace-age save should reach the saved phase")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.age == nil, "a whitespace-only age must store nil age")
  }

  // MARK: - Malformed / overflow age blocks the save

  func testMalformedAgeLettersBlockSaveWithWholeNumberMessage() throws {
    try assertInvalidAgeBlocksSave(ageText: "abc", expectedMessage: "Age must be a whole number.")
  }

  func testMalformedAgeEmbeddedSpaceBlockSaveWithWholeNumberMessage() throws {
    try assertInvalidAgeBlocksSave(ageText: "1 2", expectedMessage: "Age must be a whole number.")
  }

  func testOverflowAgeBlocksWithWholeNumberMessage() throws {
    try assertInvalidAgeBlocksSave(
      ageText: "99999999999999999999",
      expectedMessage: "Age must be a whole number.")
  }

  func testBelowRangeAgeBlocksSaveWithRangeMessage() throws {
    try assertInvalidAgeBlocksSave(ageText: "12", expectedMessage: "Age must be between 13 and 100.")
  }

  func testAboveRangeAgeBlocksSaveWithRangeMessage() throws {
    try assertInvalidAgeBlocksSave(ageText: "101", expectedMessage: "Age must be between 13 and 100.")
  }

  /// Shared literal control: an invalid age shows the expected message, the
  /// save attempt never reaches the repository, and the database is untouched.
  private func assertInvalidAgeBlocksSave(ageText: String, expectedMessage: String) throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)
    let before = try SyntheticDatabase.contentDump(at: path)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    let flow = TestFlow.make(store: store)
    flow.load()
    flow.setAgeText(ageText)

    guard case .editing(_, validation: let invalidValidation) = flow.phase else {
      XCTFail("expected editing phase after setting the age text")
      return
    }
    XCTAssertTrue(
      invalidValidation == .invalid(message: expectedMessage),
      "the invalid age should surface the expected message in the editing phase")

    flow.save()

    XCTAssertTrue(store.saveInvocations == 0, "an invalid age must block the repository write")
    guard case .editing(_, validation: let stillInvalid) = flow.phase else {
      XCTFail("a blocked save should stay in the editing phase")
      return
    }
    XCTAssertTrue(
      stillInvalid == .invalid(message: expectedMessage),
      "the validation error should remain visible after the blocked save")

    let after = try SyntheticDatabase.contentDump(at: path)
    XCTAssertTrue(before == after, "an invalid age must never write to the database")
  }

  // MARK: - Valid ages persist

  func testSaveLowerBoundAgePersists() throws {
    try assertValidAgeSavesAndPersists(ageText: "13", expectedAge: 13)
  }

  func testSaveUpperBoundAgePersists() throws {
    try assertValidAgeSavesAndPersists(ageText: "100", expectedAge: 100)
  }

  func testSaveMiddleAgePersists() throws {
    try assertValidAgeSavesAndPersists(ageText: "42", expectedAge: 42)
  }

  private func assertValidAgeSavesAndPersists(ageText: String, expectedAge: Int) throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let flow = TestFlow.make(store: store, onSaved: { savedCount += 1 })
    flow.load()
    flow.setAgeText(ageText)

    guard case .editing(_, validation: let validValidation) = flow.phase else {
      XCTFail("expected editing phase after setting the age text")
      return
    }
    XCTAssertTrue(validValidation == .ok, "an in-bounds age should validate ok")

    flow.save()

    XCTAssertTrue(flow.phase == .saved, "a valid age save should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "a successful save should fire onSaved exactly once")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.age == expectedAge, "the edited age should persist exactly")
    XCTAssertTrue(
      refetched.displayName == seeded.displayName,
      "an age-only save must not change the display name")
  }

  // MARK: - Unrelated-field preservation

  func testSavePreservesAllUnrelatedFields() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    let flow = TestFlow.make(store: store)
    flow.load()
    // Only name and age are edited; everything else must survive untouched.
    flow.setDisplayNameText("Edited Name")
    flow.setAgeText("34")

    flow.save()

    XCTAssertTrue(flow.phase == .saved, "the edited save should reach the saved phase")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.displayName == "Edited Name", "the edited display name should persist")
    XCTAssertTrue(refetched.age == 34, "the edited age should persist")
    XCTAssertTrue(refetched.goal == .weightLoss, "the goal must be preserved through the save")
    XCTAssertTrue(refetched.dailyCalories == 1800, "daily calories must be preserved through the save")
    XCTAssertTrue(refetched.proteinPct == 0.40, "the protein pct must be preserved through the save")
    XCTAssertTrue(refetched.carbsPct == 0.35, "the carbs pct must be preserved through the save")
    XCTAssertTrue(refetched.fatPct == 0.25, "the fat pct must be preserved through the save")
    XCTAssertTrue(
      refetched.dietaryRestrictions == "[\"vegan\"]",
      "dietary restrictions must be preserved through the save")
    XCTAssertTrue(
      refetched.allergenIngredientIds == "[\"3\",\"7\"]",
      "allergen ingredient ids must be preserved through the save")
    XCTAssertTrue(
      refetched.updatedAt == SyntheticProfile.fixedUpdatedAt,
      "the loaded updated date must be preserved through the save")
  }

  // MARK: - Save failure retains input; retry persists

  func testSaveFailureRetainsDraftAndRetryPersists() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)
    let before = try SyntheticDatabase.contentDump(at: path)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let flow = TestFlow.make(store: store, onSaved: { savedCount += 1 })
    flow.load()
    flow.setDisplayNameText("Edited Name")
    flow.setAgeText("34")

    store.failNextSave = true
    flow.save()

    guard case .saveFailed(let failedDraft, let failedSaveMessage) = flow.phase else {
      XCTFail("a failed save must land in the saveFailed phase")
      return
    }
    XCTAssertTrue(
      failedSaveMessage == ControlledProfileStore.Failure.injectedSave.localizedDescription,
      "the saveFailed message must come from the injected failure")
    XCTAssertTrue(
      failedDraft.displayNameText == "Edited Name",
      "the saveFailed draft must retain the edited name text")
    XCTAssertTrue(
      failedDraft.ageText == "34",
      "the saveFailed draft must retain the edited age text")
    assertProfile(failedDraft.profile, matches: seeded)
    XCTAssertTrue(store.saveInvocations == 1, "the failed attempt should reach the save closure once")
    XCTAssertTrue(savedCount == 0, "onSaved must not fire on a failed save")

    let after = try SyntheticDatabase.contentDump(at: path)
    XCTAssertTrue(before == after, "a failed save must not write to the database")

    store.failNextSave = false
    flow.retrySave()

    XCTAssertTrue(flow.phase == .saved, "retry after a cleared failure should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "the successful retry should fire onSaved exactly once")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.displayName == "Edited Name", "the retried edit should persist the name")
    XCTAssertTrue(refetched.age == 34, "the retried edit should persist the age")
  }

  // MARK: - Exactly-one callback

  func testSaveSuccessInvokesOnSavedExactlyOnce() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let flow = TestFlow.make(store: store, onSaved: { savedCount += 1 })
    flow.load()
    flow.setAgeText("34")

    flow.save()

    XCTAssertTrue(flow.phase == .saved, "the save should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "onSaved should fire exactly once on success")
  }

  // MARK: - Reentrancy guards during the save pipeline

  func testReentrantSaveWhileSavingDoesNotDoubleInvoke() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let box = WeakFlowBox()
    var reentered = false
    var observedPhaseDuringReentry: ProfileBasicsPhase?
    let flow = ProfileBasicsFlow(
      fetchProfile: { try store.fetchProfile() },
      saveProfile: { profile in
        if !reentered {
          reentered = true
          observedPhaseDuringReentry = box.flow?.phase
          box.flow?.save()  // reentrant save() while the outer save is in flight
        }
        try store.saveProfile(profile)
      },
      onSaved: { savedCount += 1 })
    box.flow = flow
    flow.load()
    flow.setAgeText("34")

    flow.save()

    guard let observedPhaseDuringReentry, case .saving = observedPhaseDuringReentry else {
      XCTFail("the reentrant save should observe the saving phase")
      return
    }
    XCTAssertTrue(flow.phase == .saved, "the outer save should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "a reentrant save must not double-invoke onSaved")
    XCTAssertTrue(
      store.saveInvocations == 1,
      "a reentrant save while saving must be a no-op (no second closure entry)")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.age == 34, "the single real write should persist the edit")
  }

  func testReentrantSaveWhileValidatingDoesNotDoubleInvoke() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.make(age: 30)
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    var savedCount = 0
    let box = WeakFlowBox()
    var reentered = false
    var observedValidating = false
    let flow = ProfileBasicsFlow(
      fetchProfile: { try store.fetchProfile() },
      saveProfile: { try store.saveProfile($0) },
      onSaved: { savedCount += 1 })
    box.flow = flow
    flow.onPhaseChange = { phase in
      if case .validating = phase {
        observedValidating = true
        if !reentered {
          reentered = true
          box.flow?.save()  // reentrant save() while validating
        }
      }
    }
    flow.load()
    flow.setAgeText("34")

    flow.save()

    XCTAssertTrue(observedValidating, "the core should report the validating phase on onPhaseChange")
    XCTAssertTrue(flow.phase == .saved, "the outer save should reach the saved phase")
    XCTAssertTrue(savedCount == 1, "a reentrant save must not double-invoke onSaved")
    XCTAssertTrue(
      store.saveInvocations == 1,
      "a reentrant save while validating must be a no-op")
    let refetched = try UserDataRepository(db: db).fetchHealthProfile()
    XCTAssertTrue(refetched.age == 34, "the single real write should persist the edit")
  }
}
