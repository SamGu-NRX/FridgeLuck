import Foundation
import GRDB
import XCTest

@testable import BackupCheck

final class RestoreCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func bump() {
    lock.lock()
    value += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

final class BackupCheckTests: XCTestCase {
  // MARK: Round trip

  func testExportThenDecodeIsByteStable() async throws {
    let queue = try Fixtures.populatedQueue("stable")
    let data = try await Fixtures.makeArchive(from: queue)
    let decoded = try BackupArchiveCodec.decode(data)
    let reencoded = try BackupArchiveCodec.encode(decoded)
    XCTAssertEqual(data, reencoded, "decode-encode is not byte-identical")
  }

  func testPopulatedRoundTripPreservesEveryRow() async throws {
    let source = try Fixtures.populatedQueue("source")
    let data = try await Fixtures.makeArchive(from: source)

    // Restore into a database with different live data.
    let target = try Fixtures.populatedQueue("target")
    try await target.write { db in
      try db.execute(sql: "DELETE FROM inventory_lots")
      try db.execute(sql: "DELETE FROM inventory_items")
      try db.execute(sql: "DELETE FROM cooking_history_nutrition_lines")
      try db.execute(sql: "DELETE FROM cooking_history_nutrition_snapshots")
      try db.execute(sql: "DELETE FROM cooking_history_swaps")
      try db.execute(sql: "DELETE FROM cooking_history")
      try db.execute(sql: "DELETE FROM recipes")
    }

    let engine = Fixtures.engine(target)
    let preview = try await engine.stageRestore(archiveData: data)
    _ = try await engine.commitRestore(preview)

    let archive = try BackupArchiveCodec.decode(data)
    for manifest in archive.tables {
      let count = try await target.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(manifest.name)") ?? -1
      }
      XCTAssertEqual(
        count, manifest.rowCount,
        "\(manifest.name): live row count \(count) != manifest \(manifest.rowCount)")
    }
  }

  func testRestoreActuallyReplacesExistingState() async throws {
    let source = try Fixtures.populatedQueue("replace-source")
    let data = try await Fixtures.makeArchive(from: source)

    let target = try Fixtures.populatedQueue("replace-target")
    try await target.write { db in
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) "
          + "VALUES (99, 'Leftover Target Recipe', 5, 1, 'x', 0, 'user')")
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium) "
          + "VALUES (7, 'Ghost Pepper Jelly', 250.0, 0.0, 60.0, 0.0, 0.0, 55.0, 20.0)")
    }

    let engine = Fixtures.engine(target)
    let preview = try await engine.stageRestore(archiveData: data)
    _ = try await engine.commitRestore(preview)

    let leftoverRecipes = try await target.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes WHERE id = 99") ?? -1
    }
    XCTAssertEqual(leftoverRecipes, 0, "restore left pre-restore recipes behind")
    let ghost = try await target.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients WHERE id = 7") ?? -1
    }
    XCTAssertEqual(ghost, 0, "restore left pre-restore ingredients behind")

    let eggs = try await target.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients WHERE name = 'Eggs'") ?? -1
    }
    XCTAssertEqual(eggs, 1)
  }

  func testRepeatImportIsIdempotent() async throws {
    let source = try Fixtures.populatedQueue("idem-source")
    let data = try await Fixtures.makeArchive(from: source)
    let target = try Fixtures.populatedQueue("idem-target")
    let staging = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fl-safety-\(UUID().uuidString)")

    for _ in 0..<2 {
      let engine = BackupRestoreEngine(
        writer: target, databasePath: target.path, documentsDirectory: nil,
        stagingRoot: staging)
      let preview = try await engine.stageRestore(archiveData: data)
      _ = try await engine.commitRestore(preview)
    }

    let archive = try BackupArchiveCodec.decode(data)
    for manifest in archive.tables {
      let count = try await target.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(manifest.name)") ?? -1
      }
      XCTAssertEqual(count, manifest.rowCount, "\(manifest.name) drifted after re-import")
    }
  }

  // MARK: Photos off by default

  func testPhotosOffByDefaultAndFlagTogglesThem() async throws {
    let documents = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fl-docs-\(UUID().uuidString)", isDirectory: true)
    let mealPhotos = documents.appendingPathComponent("MealPhotos", isDirectory: true)
    try FileManager.default.createDirectory(at: mealPhotos, withIntermediateDirectories: true)
    try Data("fake-jpeg-bytes".utf8)
      .write(to: mealPhotos.appendingPathComponent("8A2C-omelette.jpg"))

    let queue = try Fixtures.populatedQueue("photos")
    let engine = Fixtures.engine(queue, documentsDirectory: documents)

    let without = try await engine.exportArchive(includesPhotos: false)
    let decodedWithout = try BackupArchiveCodec.decode(without)
    XCTAssertFalse(decodedWithout.includesPhotos)
    XCTAssertTrue(decodedWithout.photos?.isEmpty ?? true)

    let with = try await engine.exportArchive(includesPhotos: true)
    let decodedWith = try BackupArchiveCodec.decode(with)
    XCTAssertTrue(decodedWith.includesPhotos)
    XCTAssertEqual(decodedWith.photos?.count, 1)
    XCTAssertEqual(decodedWith.photos?.first?.relativePath, "MealPhotos/8A2C-omelette.jpg")
  }

  // MARK: Structural abuse

  func testUnsupportedSchemaVersionRefuses() async throws {
    var archive = try await decodedSeededArchive()
    archive.schemaVersion = 21
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertThrowsError(try BackupArchiveCodec.decode(data)) { error in
      XCTAssertEqual(
        error as? BackupArchiveError, .unsupportedSchemaVersion(21), "\(error)")
    }
  }

  func testUnknownTableRefuses() async throws {
    var archive = try await decodedSeededArchive()
    archive.tables.append(
      .init(
        name: "sneaky_exfil", tableVersion: 1, tableClass: "userRecords", columns: ["k"],
        rowCount: 0, rowsSHA256: ""))
    archive.rows["sneaky_exfil"] = []
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertThrowsError(try BackupArchiveCodec.decode(data)) { error in
      XCTAssertEqual(
        error as? BackupArchiveError, .unknownTable("sneaky_exfil"), "\(error)")
    }
  }

  func testHashMismatchRefusesTamperedCells() async throws {
    let queue = try Fixtures.populatedQueue("tamper")
    let data = try await Fixtures.makeArchive(from: queue)

    var tampered = data
    let marker = Data("\"s:Bundled Omelette\"".utf8)
    guard let range = tampered.range(of: marker) else {
      return XCTFail("marker not found in archive bytes")
    }
    tampered[range.lowerBound + 3] = UInt8(ascii: "X")
    XCTAssertThrowsError(try BackupArchiveCodec.decode(tampered)) { error in
      guard case BackupArchiveError.hashMismatch = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
  }

  func testOversizeRefuses() async throws {
    var archive = try await decodedSeededArchive()
    archive.rows["recipes"] = archive.rows["recipes"] ?? []
    archive.rows["recipes"]!.append(
      ["i:9999", "s:" + String(repeating: "A", count: 300_000), "i:30", "i:1", "s:x", "i:0", "s:bundled", nil]
    )
    Fixtures.resign(&archive)
    let tight = BackupLimits(
      maxArchiveBytes: 128 * 1024, maxRowsPerTable: 1_000, maxPhotoCount: 10, maxPhotoBytes: 1024)
    XCTAssertThrowsError(try BackupArchiveCodec.encode(archive, limits: tight)) { error in
      guard case BackupArchiveError.sizeLimitExceeded = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
    // The same archive passes under standard limits.
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertNoThrow(try BackupArchiveCodec.decode(data))
  }

  // MARK: Semantic validation

  func testDanglingRecipeIngredientRefuses() async throws {
    var archive = try await decodedSeededArchive()
    for i in archive.rows["recipe_ingredients"]!.indices {
      archive.rows["recipe_ingredients"]![i][1] = "i:9999"
    }
    Fixtures.resign(&archive)
    XCTAssertThrowsError(try BackupValidator.validateSemantics(archive)) { error in
      guard let validationError = error as? BackupValidationError else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(
        validationError.violations.contains { $0.table == "recipe_ingredients" },
        "\(validationError.violations)")
    }
  }

  func testOutOfRangeAmountRefuses() async throws {
    var archive = try await decodedSeededArchive()
    // confidence_score above 1 on an inventory lot.
    for i in archive.rows["inventory_lots"]!.indices {
      archive.rows["inventory_lots"]![i][5] = "d:1.5"
    }
    Fixtures.resign(&archive)
    XCTAssertThrowsError(try BackupValidator.validateSemantics(archive)) { error in
      guard let validationError = error as? BackupValidationError else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(
        validationError.violations.contains {
          $0.table == "inventory_lots" && $0.detail.contains("confidence_score")
        }, "\(validationError.violations)")
    }
  }

  func testSnapshotCompletenessRefusesMissingSnapshot() async throws {
    var archive = try await decodedSeededArchive()
    archive.rows["cooking_history_nutrition_snapshots"] = []
    Fixtures.resign(&archive)
    XCTAssertThrowsError(try BackupValidator.validateSemantics(archive)) { error in
      guard let validationError = error as? BackupValidationError else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(
        validationError.violations.contains { $0.detail.contains("no nutrition snapshot") },
        "\(validationError.violations)")
    }
  }

  func testSparseNutritionLinesRefuse() async throws {
    var archive = try await decodedSeededArchive()
    // A second line for history 1 at line_index 2 leaves a gap at 1.
    archive.rows["cooking_history_nutrition_lines"]?.append([
      "i:1", "i:7", "i:2", nil, "d:1.0", "d:0.0",
      "d:0.0", "d:0.0", "d:0.0", "d:0.0", "d:0.0", "d:0.0", "d:0.0",
    ])
    Fixtures.resign(&archive)
    XCTAssertThrowsError(try BackupValidator.validateSemantics(archive)) { error in
      guard let validationError = error as? BackupValidationError else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(
        validationError.violations.contains {
          $0.table == "cooking_history_nutrition_lines"
            && $0.detail.contains("non-dense line_index")
        }, "\(validationError.violations)")
    }
  }

  func testDeletingReferencedRecipeRefusesViaForeignKey() async throws {
    var archive = try await decodedSeededArchive()
    // Drop a recipe row that cooking_history still references: the FK
    // gate inside semantic validation must refuse the archive.
    archive.rows["recipes"] = archive.rows["recipes"]?.filter { $0.count > 1 && $0[1] != "s:Bundled Omelette" }
    Fixtures.resign(&archive)
    XCTAssertThrowsError(try BackupValidator.validateSemantics(archive)) { error in
      guard let validationError = error as? BackupValidationError else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(
        validationError.violations.contains { $0.table == "cooking_history" },
        "\(validationError.violations)")
    }
  }

  // MARK: Photo abuse

  func testPhotoPathTraversalRefuses() async throws {
    var archive = try await decodedSeededArchive()
    archive.includesPhotos = true
    let payload = Data("jpeg".utf8)
    archive.photos = [
      .init(
        relativePath: "../../etc/passwd", sha256: "aa",
        base64Data: payload.base64EncodedString())
    ]
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertThrowsError(try BackupArchiveCodec.decode(data)) { error in
      guard case BackupArchiveError.photoPathRejected = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
  }

  func testPhotoHashMismatchRefuses() async throws {
    var archive = try await decodedSeededArchive()
    archive.includesPhotos = true
    let payload = Data("jpeg".utf8)
    archive.photos = [
      .init(
        relativePath: "MealPhotos/x.jpg", sha256: "deadbeef",
        base64Data: payload.base64EncodedString())
    ]
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertThrowsError(try BackupArchiveCodec.decode(data)) { error in
      guard case BackupArchiveError.photoHashMismatch = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
  }

  func testPhotosWithFlagOffRefuse() async throws {
    var archive = try await decodedSeededArchive()
    archive.includesPhotos = false
    let payload = Data("jpeg".utf8)
    archive.photos = [
      .init(
        relativePath: "MealPhotos/x.jpg", sha256: "41e5787e9f28562d07b891b1816b492309d646c0f2829743fa4963a9f9cc1d61",
        base64Data: payload.base64EncodedString())
    ]
    let data = try BackupArchiveCodec.encode(archive)
    XCTAssertThrowsError(try BackupArchiveCodec.decode(data)) { error in
      guard case BackupArchiveError.malformedArchive = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
  }

  // MARK: Staged restore

  func testSuccessfulRestorePrunesItsSafetyCopy() async throws {
    let source = try Fixtures.populatedQueue("safety-source")
    let data = try await Fixtures.makeArchive(from: source)
    let target = try Fixtures.populatedQueue("safety-target")
    let staging = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fl-safety-\(UUID().uuidString)")

    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: staging)
    let preview = try await engine.stageRestore(archiveData: data)
    _ = try await engine.commitRestore(preview)

    let remaining = try FileManager.default.contentsOfDirectory(atPath: staging.path)
    XCTAssertEqual(
      remaining.filter { $0.hasPrefix("safety-") }.count, 0,
      "successful restore must prune its own safety copy: \(remaining)")
  }

  func testFailedValidationLeavesLiveStateUntouchedAndSilent() async throws {
    let target = try Fixtures.populatedQueue("rollback")
    let before = try snapshotCounts(target)

    var archive = try await decodedSeededArchive()
    archive.rows["recipe_ingredients"]![0][1] = "i:9999"
    Fixtures.resign(&archive)
    let badData = try BackupArchiveCodec.encode(archive)

    let center = NotificationCenter()
    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fl-safety-\(UUID().uuidString)"),
      center: center)

    let notified = RestoreCounter()
    let observer = center.addObserver(
      forName: .fridgeLuckUserDataDidRestore, object: nil, queue: nil
    ) { _ in notified.bump() }
    defer { center.removeObserver(observer) }

    do {
      _ = try await engine.stageRestore(archiveData: badData)
      XCTFail("staging should have refused the invalid archive")
    } catch {
      // expected: BackupValidationError
    }
    XCTAssertEqual(notified.count, 0, "no completion event before a commit")

    let after = try snapshotCounts(target)
    XCTAssertEqual(before, after, "failed staging mutated live state")
  }

  func testMidTransactionFailureRollsBackCompletely() async throws {
    let target = try Fixtures.populatedQueue("midfail")
    let before = try snapshotCounts(target)

    // Valid at staging time; the staged preview is then mutated between
    // staging and commit so the in-transaction completeness re-check
    // fails after deletes have already run.
    let goodData = try await Fixtures.makeArchive(from: Fixtures.populatedQueue("midfail-src"))
    let center = NotificationCenter()
    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fl-safety-\(UUID().uuidString)"),
      center: center)

    let notified = RestoreCounter()
    let observer = center.addObserver(
      forName: .fridgeLuckUserDataDidRestore, object: nil, queue: nil
    ) { _ in notified.bump() }
    defer { center.removeObserver(observer) }

    do {
      var preview = try await engine.stageRestore(archiveData: goodData)
      var patched = preview.archive
      patched.rows["cooking_history_nutrition_snapshots"] = []
      Fixtures.resign(&patched)
      let brokenPreview = RestorePreview.build(archive: patched)
      _ = try await engine.commitRestore(brokenPreview)
      XCTFail("commit should have failed on the completeness re-check")
    } catch {
      // expected
    }
    XCTAssertEqual(notified.count, 0, "no completion event on a rolled-back commit")

    let after = try snapshotCounts(target)
    XCTAssertEqual(before, after, "failed commit left partial writes behind")
  }

  func testSuccessfulCommitNotifiesOnce() async throws {
    let source = try Fixtures.populatedQueue("notify-source")
    let data = try await Fixtures.makeArchive(from: source)
    let target = try Fixtures.populatedQueue("notify-target")

    let center = NotificationCenter()
    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fl-safety-\(UUID().uuidString)"),
      center: center)

    let notified = RestoreCounter()
    let observer = center.addObserver(
      forName: .fridgeLuckUserDataDidRestore, object: nil, queue: nil
    ) { _ in notified.bump() }
    defer { center.removeObserver(observer) }

    let preview = try await engine.stageRestore(archiveData: data)
    _ = try await engine.commitRestore(preview)
    XCTAssertEqual(notified.count, 1, "exactly one completion event per committed restore")
  }

  func testDiskFailureAbortsRestoreBeforeAnyWrite() async throws {
    let target = try Fixtures.populatedQueue("diskfail")
    let before = try snapshotCounts(target)
    let data = try await Fixtures.makeArchive(from: Fixtures.populatedQueue("diskfail-src"))

    // stagingRoot pointing at an existing FILE makes directory creation fail.
    let blockedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fl-blocked-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blockedRoot)

    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: blockedRoot)

    do {
      _ = try await engine.stageRestore(archiveData: data)
      _ = try await engine.commitRestore(try await engine.stageRestore(archiveData: data))
      XCTFail("the safety copy should have failed on the blocked root")
    } catch let error as BackupRestoreEngine.RestoreError {
      guard case .safetyCopyFailed = error else { return XCTFail("\(error)") }
    }
    let after = try snapshotCounts(target)
    XCTAssertEqual(before, after)
  }

  func testPendingSafetyCopiesAreRecovered() async throws {
    let target = try Fixtures.populatedQueue("recover")
    let staging = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fl-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let orphan = staging.appendingPathComponent("safety-orphan-crash", isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("leftover".utf8).write(to: orphan.appendingPathComponent("original.sqlite"))

    let data = try await Fixtures.makeArchive(from: Fixtures.populatedQueue("recover-src"))
    let engine = BackupRestoreEngine(
      writer: target, databasePath: target.path, documentsDirectory: nil,
      stagingRoot: staging)
    let preview = try await engine.stageRestore(archiveData: data)
    _ = try await engine.commitRestore(preview)

    let remaining = try FileManager.default.contentsOfDirectory(atPath: staging.path)
    XCTAssertTrue(remaining.isEmpty, "orphan safety copies must be swept: \(remaining)")
  }

  // MARK: Helpers

  func snapshotCounts(_ queue: DatabaseQueue) throws -> [String: Int] {
    try queue.read { db in
      var counts: [String: Int] = [:]
      for table in [
        "ingredients", "recipes", "recipe_ingredients", "cooking_history",
        "cooking_history_nutrition_snapshots", "cooking_history_nutrition_lines",
        "inventory_lots", "inventory_events", "inventory_items",
      ] {
        counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
      }
      return counts
    }
  }

  func decodedSeededArchive() async throws -> BackupArchive {
    let source = try Fixtures.populatedQueue("seeded-\(UUID().uuidString)")
    let data = try await Fixtures.makeArchive(from: source)
    return try BackupArchiveCodec.decode(data)
  }
}
