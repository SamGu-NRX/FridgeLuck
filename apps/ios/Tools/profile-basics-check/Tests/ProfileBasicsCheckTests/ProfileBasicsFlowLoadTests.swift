import XCTest
import GRDB
@testable import ProfileBasicsCheck

/// Load-path literal controls over the real flow: failed loads permit zero
/// saves, a genuine retry carries real loaded values, load reentrancy is
/// consistent, late second loads cannot overwrite an editing draft, and
/// editing without save writes nothing.
final class ProfileBasicsFlowLoadTests: XCTestCase {

  // MARK: - Failed load permits zero saves

  func testFailedLoadPermitsZeroSavesAndWritesNothing() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)
    let before = try SyntheticDatabase.contentDump(at: path)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    store.failNextLoad = true
    let flow = TestFlow.make(store: store)
    flow.load()

    guard case .loadFailed(let failedLoadMessage) = flow.phase else {
      XCTFail("a failed load must land in the loadFailed phase")
      return
    }
    XCTAssertTrue(
      failedLoadMessage == ControlledProfileStore.Failure.injectedLoad.localizedDescription,
      "the loadFailed message must come from the injected failure")

    // Every save-shaped entry is a no-op after a failed load.
    flow.save()
    flow.retrySave()

    XCTAssertTrue(store.saveInvocations == 0, "no save may reach the repository after a failed load")
    guard case .loadFailed = flow.phase else {
      XCTFail("a no-op save must not move the phase off loadFailed")
      return
    }

    let after = try SyntheticDatabase.contentDump(at: path)
    XCTAssertTrue(before == after, "a failed load must never write a default profile to the database")
  }

  // MARK: - Genuine retry carries real loaded values

  func testRetryLoadCarriesRealLoadedValuesIntoEditingDraft() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    let flow = TestFlow.make(store: store)

    store.failNextLoad = true
    flow.load()
    guard case .loadFailed = flow.phase else {
      XCTFail("the first load must fail as injected")
      return
    }

    store.failNextLoad = false
    flow.retryLoad()

    guard case .editing(let draft, validation: .ok) = flow.phase else {
      XCTFail("a successful retry must land in the editing phase with a valid draft")
      return
    }
    XCTAssertTrue(
      draft.profile == seeded,
      "the editing draft must carry the real loaded profile, not defaults")
    XCTAssertTrue(
      draft.displayNameText == seeded.displayName,
      "the editing draft name text must come from the loaded profile")
    XCTAssertTrue(
      draft.ageText == String(seeded.age!),
      "the editing draft age text must come from the loaded profile")
  }

  // MARK: - Load reentrancy and consistency

  func testLoadReentrancyAndConsistency() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)

    var closureCalls = 0

    let reentrantFlow = ProfileBasicsFlow(
      fetchProfile: {
        closureCalls += 1
        if closureCalls == 1 {
          // Re-entrancy probes from inside the first fetch closure.
          flow.load()
          flow.retryLoad()
        }
        return seeded
      },
      saveProfile: { _ in },
      onSaved: {})

    reentrantFlow.load()

    guard case .editing(let draft, validation: .ok) = reentrantFlow.phase else {
      XCTFail("after a load with reentrant probes the flow must sit in editing")
      return
    }
    XCTAssertTrue(draft.profile == seeded, "the draft must carry the loaded profile")
    XCTAssertTrue(closureCalls == 1, "reentrant load attempts during load must not refetch")

    // A late second load attempt cannot overwrite the editing draft.
    reentrantFlow.setAgeText("55")
    reentrantFlow.load()
    reentrantFlow.retryLoad()

    guard case .editing(let keptDraft, validation: .ok) = reentrantFlow.phase else {
      XCTFail("late load attempts must not leave the editing phase")
      return
    }
    XCTAssertTrue(keptDraft.ageText == "55", "the late second load must not overwrite the edited draft")
    XCTAssertTrue(closureCalls == 1, "late load attempts must not refetch")
  }

  // MARK: - Cancel writes nothing

  func testCancelWritesNothingToRepository() throws {
    let (db, path) = try SyntheticDatabase.make()
    let seeded = SyntheticProfile.rich()
    try seedProfile(seeded, in: db)
    let before = try SyntheticDatabase.contentDump(at: path)

    let store = ControlledProfileStore(repository: UserDataRepository(db: db))
    let flow = TestFlow.make(store: store)
    flow.load()
    flow.setDisplayNameText("Cancelled Name")
    flow.setAgeText("55")

    guard case .editing = flow.phase else {
      XCTFail("edits must keep the flow in the editing phase")
      return
    }
    XCTAssertTrue(store.saveInvocations == 0, "no save was requested, so no write may happen")

    let after = try SyntheticDatabase.contentDump(at: path)
    XCTAssertTrue(before == after, "editing without save must leave the database untouched")
  }
}
