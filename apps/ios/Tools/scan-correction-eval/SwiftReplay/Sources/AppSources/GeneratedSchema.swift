// Generated from Migrations.swift by Scripts/sync_sources.py -- do not edit.
// Verbatim create blocks for the tables the replay touches.
import GRDB

enum ReplaySchema {
  static func migrate(_ db: Database) throws {
    try db.create(table: "ingredients") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("calories", .double).notNull()
            t.column("protein", .double).notNull()
            t.column("carbs", .double).notNull()
            t.column("fat", .double).notNull()
            t.column("fiber", .double).notNull().defaults(to: 0)
            t.column("sugar", .double).notNull().defaults(to: 0)
            t.column("sodium", .double).notNull().defaults(to: 0)
            t.column("typical_unit", .text)
            t.column("storage_tip", .text)
          }
    try db.create(table: "user_corrections") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("vision_label", .text).notNull()
            t.column("corrected_ingredient_id", .integer)
              .notNull()
              .references("ingredients")
            t.column("correction_count", .integer).defaults(to: 1)
            t.column("last_used_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            t.uniqueKey(["vision_label", "corrected_ingredient_id"])
          }
    try db.create(
            index: "idx_corrections_label",
            on: "user_corrections",
            columns: ["vision_label"]
          )
  }
}