import Foundation
import GRDB

/// All database schema migrations in one place.
enum DatabaseMigrations {
  static func migrate(_ db: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()

    // MARK: - V1: Initial Schema

    migrator.registerMigration("v1_initial") { db in
      // Recipes
      try db.create(table: "recipes") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("title", .text).notNull()
        t.column("time_minutes", .integer).notNull()
        t.column("servings", .integer).notNull().defaults(to: 1)
        t.column("instructions", .text).notNull()
        t.column("tags", .integer).defaults(to: 0)
        t.column("source", .text).defaults(to: "bundled")
        t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }

      // Ingredients with full nutrition data per 100g
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

      // Recipe-Ingredient join table WITH quantities
      try db.create(table: "recipe_ingredients") { t in
        t.column("recipe_id", .integer)
          .notNull()
          .references("recipes", onDelete: .cascade)
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients")
        t.column("is_required", .boolean).notNull().defaults(to: true)
        t.column("quantity_grams", .double).notNull()
        t.column("display_quantity", .text).notNull()
        t.primaryKey(["recipe_id", "ingredient_id"])
      }

      // User corrections for continual learning
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

      // Health profile (single row, set during onboarding)
      try db.create(table: "health_profile") { t in
        t.primaryKey("id", .integer, onConflict: .replace)
          .check { $0 == 1 }
        t.column("goal", .text).defaults(to: "general")
        t.column("daily_calories", .integer)
        t.column("protein_pct", .double).defaults(to: 0.25)
        t.column("carbs_pct", .double).defaults(to: 0.45)
        t.column("fat_pct", .double).defaults(to: 0.30)
        t.column("dietary_restrictions", .text).defaults(to: "[]")
        t.column("allergen_ingredient_ids", .text).defaults(to: "[]")
        t.column("updated_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }

      // Cooking history for personalization + streaks
      try db.create(table: "cooking_history") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("recipe_id", .integer)
          .notNull()
          .references("recipes")
        t.column("cooked_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
        t.column("rating", .integer)
          .check { $0 >= 1 && $0 <= 5 }
      }

      // Badges
      try db.create(table: "badges") { t in
        t.primaryKey("id", .text)
        t.column("earned_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }

      // Streaks
      try db.create(table: "streaks") { t in
        t.primaryKey("date", .text)
        t.column("meals_cooked", .integer).defaults(to: 0)
      }

      // Indexes for query performance
      try db.create(
        index: "idx_ri_ingredient",
        on: "recipe_ingredients",
        columns: ["ingredient_id"]
      )
      try db.create(
        index: "idx_ri_recipe",
        on: "recipe_ingredients",
        columns: ["recipe_id"]
      )
      try db.create(
        index: "idx_corrections_label",
        on: "user_corrections",
        columns: ["vision_label"]
      )
      try db.create(
        index: "idx_history_recipe",
        on: "cooking_history",
        columns: ["recipe_id"]
      )
      try db.create(
        index: "idx_history_date",
        on: "cooking_history",
        columns: ["cooked_at"]
      )
    }

    // MARK: - V2: Ingredient educational fields

    migrator.registerMigration("v2_ingredient_education_fields") { db in
      try db.alter(table: "ingredients") { t in
        t.add(column: "pairs_with", .text)
        t.add(column: "notes", .text)
      }
    }

    // MARK: - V3: Prepared dish templates

    migrator.registerMigration("v3_dish_templates") { db in
      try db.create(table: "dish_templates") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull().unique()
        t.column("base_calories", .double).notNull()
        t.column("base_protein", .double).notNull()
        t.column("base_carbs", .double).notNull()
        t.column("base_fat", .double).notNull()
        t.column("notes", .text)
      }

      let templates: [(String, Double, Double, Double, Double, String)] = [
        ("Fried Rice", 520, 14, 68, 20, "Includes oil variance and mixed veg."),
        ("Curry", 460, 18, 35, 26, "Assumes coconut or cream-based sauce."),
        ("Pasta Bowl", 610, 20, 88, 18, "Cooked pasta with sauce and toppings."),
        ("Soup Bowl", 280, 14, 30, 10, "Broth-heavy home serving."),
        ("Stir Fry", 430, 24, 35, 20, "Protein + vegetables + sauce."),
        ("Sandwich", 390, 18, 42, 16, "Two-slice default sandwich."),
      ]

      for (name, cal, protein, carbs, fat, notes) in templates {
        try db.execute(
          sql: """
            INSERT INTO dish_templates
                (name, base_calories, base_protein, base_carbs, base_fat, notes)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [name, cal, protein, carbs, fat, notes]
        )
      }
    }

    // MARK: - V4: Ingredient aliases for fuzzy search

    migrator.registerMigration("v4_ingredient_aliases") { db in
      try db.create(table: "ingredient_aliases") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("alias", .text).notNull()
        t.uniqueKey(["ingredient_id", "alias"])
      }

      try db.create(
        index: "idx_ingredient_alias_lookup",
        on: "ingredient_aliases",
        columns: ["alias"]
      )
    }

    // MARK: - V5: Ingredient display metadata

    migrator.registerMigration("v5_ingredient_display_metadata") { db in
      try db.alter(table: "ingredients") { t in
        t.add(column: "description", .text)
        t.add(column: "category_label", .text)
        t.add(column: "sprite_group", .text)
        t.add(column: "sprite_key", .text)
      }

      // Backfill description from existing notes for older rows.
      try db.execute(
        sql: """
          UPDATE ingredients
          SET description = COALESCE(description, notes, '')
          WHERE description IS NULL OR description = ''
          """
      )
    }

    // MARK: - V6: Cooking history photo + serving tracking

    migrator.registerMigration("v6_cooking_photo_servings") { db in
      try db.alter(table: "cooking_history") { t in
        t.add(column: "image_path", .text)
        t.add(column: "servings_consumed", .integer)
      }
    }

    try migrator.migrate(db)
  }
}
