import Foundation
import GRDB

/// Repository for user-specific data: health profile, badges, preferences.
final class UserDataRepository: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - Health Profile

  func fetchHealthProfile() throws -> HealthProfile {
    try db.read { db in
      try HealthProfile.fetchOne(db, key: 1) ?? .default
    }
  }

  func saveHealthProfile(_ profile: HealthProfile) throws {
    try db.write { db in
      var mutable = profile
      mutable.id = 1
      try mutable.save(db)
    }
  }

  func hasCompletedOnboarding() throws -> Bool {
    try db.read { db in
      (try HealthProfile.fetchOne(db, key: 1)) != nil
    }
  }

  // MARK: - Badges

  func earnBadge(id: String) throws {
    try db.write { db in
      var badge = Badge(id: id)
      try badge.insert(db)
    }
  }

  func earnedBadges() throws -> [Badge] {
    try db.read { db in
      try Badge.order(Badge.Columns.earnedAt.desc).fetchAll(db)
    }
  }

  func hasBadge(id: String) throws -> Bool {
    try db.read { db in
      (try Badge.fetchOne(db, key: id)) != nil
    }
  }

  // MARK: - Stats

  func totalMealsCooked() throws -> Int {
    try db.read { db in
      try CookingHistory.fetchCount(db)
    }
  }

  func totalRecipesUsed() throws -> Int {
    try db.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(DISTINCT recipe_id) FROM cooking_history
          """) ?? 0
    }
  }
}
