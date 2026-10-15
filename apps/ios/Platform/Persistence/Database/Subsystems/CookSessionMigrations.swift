import Foundation
import GRDB

/// Cook-subsystem database migrations (SPEC.md §11).
///
/// The burst5 slices add their tables here, one `migrator.append` per version. This file is
/// created by the plan slice and owns the `cook_plan*` tables; the cook-core slice adds the
/// `cook_session`/`cook_timer`/… tables to this same file.
///
/// Registration with the app's migrator is one line in `DatabaseMigrations.migrate` after the
/// core migrations (`try CookSessionMigrations.append(to: &migrator)`); until that line lands,
/// tests apply these migrations explicitly, which keeps the subsystem self-contained.
enum CookSessionMigrations {
  /// Appends the cook migrations to the shared migrator, in fixed subsystem order.
  static func append(to migrator: inout DatabaseMigrator) {
    migrator.registerMigration("cook_v1_plan_tables") { db in
      try migratePlanTables(db)
    }
  }

  /// Applies the cook migrations to a database directly (used by tests and by callers that hold
  /// no shared migrator).
  static func migrate(_ dbQueue: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()
    append(to: &migrator)
    try migrator.migrate(dbQueue)
  }

  private static func migratePlanTables(_ db: Database) throws {
    // Frozen decision records; the live pantry stays owned by the inventory subsystem —
    // allocation reads it, never writes it (SPEC.md §7, §11).
    try db.create(table: "cook_plan") { t in
      t.primaryKey("id", .text)  // plan_…
      t.column("created_at", .datetime).notNull()
      t.column("horizon_dinners", .integer).notNull().check { $0 >= 1 && $0 <= 7 }
      t.column("state", .text).notNull().defaults(to: "draft")  // draft/saved/superseded
      t.column("fit_summary", .text).notNull().defaults(to: "{}")
    }

    try db.create(table: "cook_plan_dinner") { t in
      t.primaryKey("id", .text)
      t.column("plan_id", .text).notNull().references("cook_plan", onDelete: .cascade)
      t.column("position", .integer).notNull().check { $0 >= 1 && $0 <= 7 }
      t.column("recipe_ref", .text).notNull()  // RecipeRef JSON
      t.column("servings", .integer).notNull()
      t.column("state", .text).notNull().defaults(to: "planned")  // planned/cooked/skipped
      t.column("cooked_session_id", .text)
    }

    try db.create(table: "cook_plan_line") { t in
      t.primaryKey("id", .text)
      t.column("dinner_id", .text).notNull().references("cook_plan_dinner", onDelete: .cascade)
      t.column("ingredient_id", .integer).notNull()
      // Additive to the §11 column list: the shopping list must distinguish required short
      // lines from optional ones, and §11's columns carry no required flag.
      t.column("name", .text).notNull()
      t.column("is_required", .boolean).notNull().defaults(to: true)
      t.column("required_quantity", .text)  // {value, unit} JSON, NULL when quantity unknown
      t.column("line_state", .text).notNull()  // sufficient/short/quantity_unknown/assumed_staple/needs_reconfirming
      t.column("short_quantity", .text)  // {value, unit} JSON, required when line_state=short
      t.column("swap", .text)  // PlanSwap JSON, NULL when no substitution applied
    }

    try db.create(index: "idx_cook_plan_dinner_plan", on: "cook_plan_dinner", columns: ["plan_id"])
    try db.create(
      index: "idx_cook_plan_line_dinner", on: "cook_plan_line", columns: ["dinner_id"])
  }
}
