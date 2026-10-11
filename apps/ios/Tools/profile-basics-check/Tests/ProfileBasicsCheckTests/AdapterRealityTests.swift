import XCTest
import GRDB
@testable import ProfileBasicsCheck

/// Adapter-reality proof: the controlled store wraps the REAL UserDataRepository
/// over a REAL GRDB DatabaseQueue migrated by the REAL production migrations,
/// against a synthetic temp-dir database. Fail injection throws deterministically
/// in front of the real adapter; counting wraps it without replacing it.
final class AdapterRealityTests: XCTestCase {

  func testFailInjectionFlagsThrowDeterministicallyAndAutoClear() throws {
    let (db, _) = try SyntheticDatabase.make()
    let store = ControlledProfileStore(repository: UserDataRepository(db: db))

    // Load injection: throws the injected error exactly once, then clears.
    store.failNextLoad = true
    do {
      _ = try store.fetchProfile()
      XCTFail("expected the injected load failure")
    } catch {
      guard case ControlledProfileStore.Failure.injectedLoad = error else {
        XCTFail("expected the injected load error")
        return
      }
    }
    XCTAssertTrue(store.failNextLoad == false, "load injection must auto-clear after one attempt")
    XCTAssertTrue(store.loadAttempts == 1, "the injected attempt must still be counted")

    // With the flag cleared, the real adapter serves the real (empty) database.
    let fetched = try store.fetchProfile()
    XCTAssertTrue(
      fetched == HealthProfile.default,
      "an empty synthetic database should fetch the default profile")
    XCTAssertTrue(store.loadAttempts == 2, "the cleared-path fetch must be counted")

    // Save injection: throws the injected error exactly once, then clears.
    store.failNextSave = true
    do {
      try store.saveProfile(SyntheticProfile.make(age: 34, updatedAt: SyntheticProfile.fixedUpdatedAt))
      XCTFail("expected the injected save failure")
    } catch {
      guard case ControlledProfileStore.Failure.injectedSave = error else {
        XCTFail("expected the injected save error")
        return
      }
    }
    XCTAssertTrue(store.failNextSave == false, "save injection must auto-clear after one attempt")
    XCTAssertTrue(store.saveInvocations == 1, "the injected attempt must still be counted")

    // The injected save failure must have left the database without a profile row.
    let untouched = try store.fetchProfile()
    XCTAssertTrue(
      untouched == HealthProfile.default,
      "an injected save failure must leave the database without a profile row")

    // With the flag cleared, the real adapter performs the real write.
    let toSave = SyntheticProfile.make(age: 34, updatedAt: SyntheticProfile.fixedUpdatedAt)
    try store.saveProfile(toSave)
    let refetched = try store.fetchProfile()
    assertProfile(refetched, matches: toSave)
    XCTAssertTrue(store.saveInvocations == 2, "the cleared-path save must be counted")
  }

  func testRealRepositorySeedSaveRefetchRoundTripOnSyntheticDatabase() throws {
    let (db, path) = try SyntheticDatabase.make()
    let repository = UserDataRepository(db: db)

    // A fresh migrated database reads as the default profile (no row yet).
    let empty = try repository.fetchHealthProfile()
    XCTAssertTrue(
      empty == HealthProfile.default,
      "a fresh synthetic database should read as the default profile")

    // Seed a fully non-default synthetic profile through the real adapter,
    // then re-fetch and demand exact field equality — the round trip proves
    // the real GRDB stack (model, repository, migrations) works on Linux.
    let seeded = SyntheticProfile.rich()
    try repository.saveHealthProfile(seeded)
    let refetched = try repository.fetchHealthProfile()
    assertProfile(refetched, matches: seeded)

    // The bytes are on disk: a fresh readonly connection sees the table.
    let dumped = try SyntheticDatabase.contentDump(at: path)
    XCTAssertTrue(dumped.contains("health_profile"), "the dump should include the health profile table")
  }
}
