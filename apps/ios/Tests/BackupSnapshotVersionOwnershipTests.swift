import Foundation
import XCTest

@testable import FridgeLuck

/// Pins the backup layer's snapshot-version gate to the snapshot owner.
///
/// `NutritionSnapshotService` (the owner of
/// `cooking_history_nutrition_snapshots`) refuses to read any snapshot
/// whose `snapshot_version` is not its `currentVersion`. The backup
/// validator must therefore refuse to restore snapshots of any other
/// version — otherwise a restore could plant rows that look present but
/// never load. The portable backup-check package cannot compile the
/// snapshot service (it transitively drags feature code), so
/// `BackupValidator` carries a documented mirror constant and this test
/// pins the two together: any drift fails the hosted macOS run.
final class BackupSnapshotVersionOwnershipTests: XCTestCase {
  func testBackupValidatorSupportedVersionMatchesSnapshotOwner() {
    XCTAssertEqual(
      BackupValidator.supportedSnapshotVersion, NutritionSnapshot.currentVersion,
      "the backup validator's snapshot-version gate must track the snapshot owner")
  }
}
