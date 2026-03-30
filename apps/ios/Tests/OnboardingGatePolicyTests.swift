import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class OnboardingGatePolicyTests: XCTestCase {
  func testHasCompletedOnboardingRejectsMissingIdentityFields() throws {
    let repository = try makeRepository()

    var profile = HealthProfile.default
    profile.displayName = "   "
    profile.age = 28
    try repository.saveHealthProfile(profile)
    XCTAssertFalse(try repository.hasCompletedOnboarding())

    profile.displayName = "Sam"
    profile.age = nil
    try repository.saveHealthProfile(profile)
    XCTAssertFalse(try repository.hasCompletedOnboarding())
  }

  func testHasCompletedOnboardingRequiresAgeInsideAllowedRange() throws {
    let repository = try makeRepository()

    var profile = HealthProfile.default
    profile.displayName = "Sam"

    profile.age = 12
    try repository.saveHealthProfile(profile)
    XCTAssertFalse(try repository.hasCompletedOnboarding())

    profile.age = 101
    try repository.saveHealthProfile(profile)
    XCTAssertFalse(try repository.hasCompletedOnboarding())

    profile.age = 29
    try repository.saveHealthProfile(profile)
    XCTAssertTrue(try repository.hasCompletedOnboarding())
  }

  private func makeRepository() throws -> UserDataRepository {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
      try db.create(table: HealthProfile.databaseTableName) { table in
        table.column("id", .integer).primaryKey()
        table.column("display_name", .text).notNull()
        table.column("age", .integer)
        table.column("goal", .text).notNull()
        table.column("daily_calories", .integer)
        table.column("protein_pct", .double).notNull()
        table.column("carbs_pct", .double).notNull()
        table.column("fat_pct", .double).notNull()
        table.column("dietary_restrictions", .text).notNull()
        table.column("allergen_ingredient_ids", .text).notNull()
        table.column("updated_at", .datetime)
      }
    }
    return UserDataRepository(db: dbQueue)
  }
}
