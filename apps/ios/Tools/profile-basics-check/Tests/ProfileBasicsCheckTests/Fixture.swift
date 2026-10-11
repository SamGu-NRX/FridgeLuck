import XCTest
import GRDB
@testable import ProfileBasicsCheck

// Shared test scaffolding for the profile-basics literal-control matrix.
//
// PRIVACY: every profile here is synthetic. No real user data is ever read,
// referenced, or logged; assertion messages use static strings only and never
// interpolate profile field values or file paths.

/// A synthetic HealthProfile builder with fixed, non-user-derived values.
enum SyntheticProfile {
  /// Fixed instant so date round-trips through the real database are exact.
  static let fixedUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)

  static func make(
    id: Int64 = 1,
    displayName: String = "Synthetic User",
    age: Int? = 30,
    goal: HealthGoal = .general,
    dailyCalories: Int? = 2000,
    proteinPct: Double = 0.30,
    carbsPct: Double = 0.45,
    fatPct: Double = 0.25,
    dietaryRestrictions: String = "[]",
    allergenIngredientIds: String = "[]"
  ) -> HealthProfile {
    HealthProfile(
      id: id,
      displayName: displayName,
      age: age,
      goal: goal,
      dailyCalories: dailyCalories,
      proteinPct: proteinPct,
      carbsPct: carbsPct,
      fatPct: fatPct,
      dietaryRestrictions: dietaryRestrictions,
      allergenIngredientIds: allergenIngredientIds,
      updatedAt: fixedUpdatedAt)
  }

  /// A fully non-default synthetic profile used for preservation tests.
  static func rich() -> HealthProfile {
    make(
      displayName: "Synthetic Rich",
      age: 41,
      goal: .weightLoss,
      dailyCalories: 1800,
      proteinPct: 0.40,
      carbsPct: 0.35,
      fatPct: 0.25,
      dietaryRestrictions: "[\"vegan\"]",
      allergenIngredientIds: "[\"3\",\"7\"]")
  }
}

/// Real production migrations applied to a REAL GRDB DatabaseQueue over a
/// synthetic database in a temporary directory.
enum SyntheticDatabase {
  static func make() throws -> (DatabaseQueue, String) {
    let dir = NSTemporaryDirectory() + "profile-basics-check-\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "synthetic.sqlite3"
    let db = try DatabaseQueue(path: path)
    try Migrations.migrate(db)
    return (db, path)
  }

  /// Byte-for-byte dump via a FRESH readonly connection: the file is what is
  /// compared, not an in-memory interpretation.
  static func contentDump(at path: String) throws -> String {
    let ro = try DatabaseQueue(path: path, readOnly: true)
    var statements: [String] = []
    let tableNames = try ro.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    }
    for table in tableNames {
      statements.append("TABLE \(table)")
      let rows = try ro.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"")
      }
      for row in rows {
        statements.append(row.description)
      }
    }
    return statements.joined(separator: "\n")
  }
}

/// Seed a synthetic profile row through the REAL repository.
func seedProfile(_ profile: HealthProfile, in db: DatabaseQueue) throws {
  let repository = UserDataRepository(db: db)
  try repository.saveHealthProfile(profile)
}

/// Exact whole-value equality between a fetched and an expected synthetic
/// profile — never a diff that would print field values.
func assertProfile(_ fetched: HealthProfile, matches expected: HealthProfile) {
  XCTAssertTrue(fetched == expected, "the fetched profile must exactly equal the expected synthetic profile")
}

/// Compare validation outcomes without echoing messages beyond what the test
/// already states statically.
func assertValidationEquality(
  _ actual: ProfileBasicsValidation,
  equals expected: ProfileBasicsValidation
) {
  XCTAssertTrue(actual == expected, "the validation outcome must equal the expected outcome")
}

/// Controlled store: wraps the REAL UserDataRepository over a REAL GRDB
/// DatabaseQueue. Deterministic fail-injection flags throw in front of the
/// real adapter exactly once and auto-clear; invocation counters wrap the real
/// adapter without replacing it.
final class ControlledProfileStore {
  enum Failure: Error {
    case injectedLoad
    case injectedSave
  }

  private let repository: UserDataRepository
  /// When true, the next fetchProfile() throws instead of calling the real
  /// adapter, then the flag clears itself.
  var failNextLoad = false
  /// When true, the next saveProfile(_:) throws instead of calling the real
  /// adapter, then the flag clears itself.
  var failNextSave = false
  /// Number of times the real fetch adapter was invoked (injected failures included).
  private(set) var loadAttempts = 0
  /// Number of times the real save adapter was invoked (injected failures included).
  private(set) var saveInvocations = 0

  init(repository: UserDataRepository) {
    self.repository = repository
  }

  func fetchProfile() throws -> HealthProfile {
    loadAttempts += 1
    if failNextLoad {
      failNextLoad = false
      throw Failure.injectedLoad
    }
    return try repository.fetchHealthProfile()
  }

  func saveProfile(_ profile: HealthProfile) throws {
    saveInvocations += 1
    if failNextSave {
      failNextSave = false
      throw Failure.injectedSave
    }
    try repository.saveHealthProfile(profile)
  }
}

/// Weak box so closures can re-enter the flow under test without retaining it.
final class WeakFlowBox {
  weak var flow: ProfileBasicsFlow?
  init(flow: ProfileBasicsFlow? = nil) {
    self.flow = flow
  }
}

/// Flow factory over the controlled store with a counted onSaved callback.
enum TestFlow {
  static func make(
    store: ControlledProfileStore,
    onSaved: (() -> Void)? = nil
  ) -> ProfileBasicsFlow {
    ProfileBasicsFlow(
      fetchProfile: { try store.fetchProfile() },
      saveProfile: { try store.saveProfile($0) },
      onSaved: onSaved ?? {})
  }
}
