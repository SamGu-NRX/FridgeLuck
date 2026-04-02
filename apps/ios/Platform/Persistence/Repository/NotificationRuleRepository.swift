import Foundation
import GRDB

final class NotificationRuleRepository: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func fetchAllRules() throws -> [NotificationRule] {
    try db.write { db in
      try seedDefaultsIfNeeded(in: db)
      return
        try NotificationRule
        .order(sql: orderingSQL)
        .fetchAll(db)
    }
  }

  func fetchRule(kind: NotificationRuleKind) throws -> NotificationRule {
    try db.write { db in
      try seedDefaultsIfNeeded(in: db)
      if let rule =
        try NotificationRule
        .filter(NotificationRule.Columns.kind == kind.rawValue)
        .fetchOne(db)
      {
        return rule
      }

      var fallback = NotificationRule.makeDefault(kind: kind)
      try fallback.insert(db)
      return fallback
    }
  }

  func saveRule(
    kind: NotificationRuleKind,
    enabled: Bool,
    hour: Int,
    minute: Int
  ) throws {
    let safeHour = min(max(hour, 0), 23)
    let safeMinute = min(max(minute, 0), 59)

    try db.write { db in
      try seedDefaultsIfNeeded(in: db)
      try db.execute(
        sql: """
          UPDATE notification_rules
          SET enabled = ?, hour = ?, minute = ?, updated_at = CURRENT_TIMESTAMP
          WHERE kind = ?
          """,
        arguments: [enabled, safeHour, safeMinute, kind.rawValue]
      )
    }
  }

  func replaceFreshnessOpportunities(with opportunities: [NotificationOpportunity]) throws {
    try db.write { db in
      try db.execute(
        sql: """
          DELETE FROM notification_opportunities
          WHERE kind = ?
          """,
        arguments: [NotificationOpportunityKind.useSoonDigest.rawValue]
      )

      for var opportunity in opportunities {
        opportunity.updatedAt = Date()
        try opportunity.save(db)
      }
    }
  }

  func fetchScheduledOpportunities(after date: Date = Date()) throws -> [NotificationOpportunity] {
    try db.read { db in
      try NotificationOpportunity
        .filter(
          NotificationOpportunity.Columns.status == NotificationOpportunityStatus.scheduled.rawValue
        )
        .filter(NotificationOpportunity.Columns.scheduledAt >= date)
        .order(NotificationOpportunity.Columns.scheduledAt.asc)
        .fetchAll(db)
    }
  }

  func markStaleFreshnessOpportunities(before date: Date = Date()) throws {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE notification_opportunities
          SET status = ?, updated_at = CURRENT_TIMESTAMP
          WHERE kind = ?
            AND scheduled_at < ?
            AND status != ?
          """,
        arguments: [
          NotificationOpportunityStatus.obsolete.rawValue,
          NotificationOpportunityKind.useSoonDigest.rawValue,
          date,
          NotificationOpportunityStatus.obsolete.rawValue,
        ]
      )
    }
  }

  private func seedDefaultsIfNeeded(in db: Database) throws {
    let count =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM notification_rules"
      ) ?? 0
    guard count == 0 else { return }

    for kind in NotificationRuleKind.allCases {
      var rule = NotificationRule.makeDefault(kind: kind)
      try rule.insert(db)
    }
  }

  private var orderingSQL: String {
    let orderedKinds = NotificationRuleKind.allCases.map(\.rawValue)
    let cases = orderedKinds.enumerated().map { index, kind in
      "WHEN '\(kind)' THEN \(index)"
    }.joined(separator: " ")
    return "CASE kind \(cases) ELSE 999 END ASC"
  }
}
