import Foundation
import GRDB

/// All database schema migrations in one place.
enum DatabaseMigrations {
  static func migrate(_ db: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()

    // MARK: - V1: Initial Schema

    migrator.registerMigration("v1_initial") { db in
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

      try db.create(table: "cooking_history") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("recipe_id", .integer)
          .notNull()
          .references("recipes")
        t.column("cooked_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
        t.column("rating", .integer)
          .check { $0 >= 1 && $0 <= 5 }
      }

      try db.create(table: "badges") { t in
        t.primaryKey("id", .text)
        t.column("earned_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(table: "streaks") { t in
        t.primaryKey("date", .text)
        t.column("meals_cooked", .integer).defaults(to: 0)
      }

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

    // MARK: - V7: USDA catalog hydration state

    migrator.registerMigration("v7_usda_catalog_state") { db in
      try db.create(table: "usda_catalog_state") { t in
        t.primaryKey("key", .text)
        t.column("value", .text).notNull()
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }
    }

    // MARK: - V8: Bundled recipe hydration state

    migrator.registerMigration("v8_bundled_recipe_state") { db in
      try db.create(table: "bundled_recipe_state") { t in
        t.primaryKey("key", .text)
        t.column("value", .text).notNull()
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }
    }

    // MARK: - V9: Smart fridge inventory tracking

    migrator.registerMigration("v9_smart_fridge_inventory") { db in
      try db.create(table: "ingredient_shelf_life_profiles") { t in
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("fridge_days", .integer)
        t.column("pantry_days", .integer)
        t.column("freezer_days", .integer)
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.primaryKey(["ingredient_id"])
      }

      try db.create(table: "inventory_lots") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("quantity_grams", .double).notNull()
        t.column("remaining_grams", .double).notNull()
        t.column("storage_location", .text).notNull().defaults(to: "unknown")
        t.column("confidence_score", .double).notNull().defaults(to: 1.0)
        t.column("source", .text).notNull().defaults(to: "manual")
        t.column("acquired_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("expires_at", .datetime)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.check(sql: "quantity_grams >= 0")
        t.check(sql: "remaining_grams >= 0")
      }

      try db.create(table: "inventory_events") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("lot_id", .integer).references("inventory_lots", onDelete: .setNull)
        t.column("event_type", .text).notNull()
        t.column("quantity_delta_grams", .double).notNull()
        t.column("confidence_score", .double).notNull().defaults(to: 1.0)
        t.column("reason", .text)
        t.column("source_ref", .text)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(table: "inventory_items") { t in
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("total_remaining_grams", .double).notNull().defaults(to: 0)
        t.column("average_confidence_score", .double).notNull().defaults(to: 1.0)
        t.column("last_updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.primaryKey(["ingredient_id"])
      }

      try db.create(
        index: "idx_inventory_lots_lookup",
        on: "inventory_lots",
        columns: ["ingredient_id", "expires_at", "acquired_at"]
      )
      try db.create(
        index: "idx_inventory_lots_remaining",
        on: "inventory_lots",
        columns: ["remaining_grams"]
      )
      try db.create(
        index: "idx_inventory_events_ingredient",
        on: "inventory_events",
        columns: ["ingredient_id", "created_at"]
      )
      try db.create(
        index: "idx_inventory_events_lot",
        on: "inventory_events",
        columns: ["lot_id"]
      )
    }

    // MARK: - V10: Confidence learning signal history + trust vectors

    migrator.registerMigration("v10_confidence_learning") { db in
      try db.create(table: "confidence_signal_events") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("signal_key", .text).notNull()
        t.column("context_key", .text)
        t.column("raw_score", .double).notNull()
        t.column("outcome_reward", .double).notNull()
        t.column("note", .text)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(table: "trust_vector_state") { t in
        t.primaryKey("signal_key", .text)
        t.column("alpha", .double).notNull().defaults(to: 4.0)
        t.column("beta", .double).notNull().defaults(to: 3.0)
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(
        index: "idx_confidence_events_signal",
        on: "confidence_signal_events",
        columns: ["signal_key", "created_at"]
      )
      try db.create(
        index: "idx_confidence_events_context",
        on: "confidence_signal_events",
        columns: ["context_key"]
      )
    }

    // MARK: - V11: Repair cooking-history recipe links with missing ingredients

    migrator.registerMigration("v11_reconcile_ingredientless_recipe_links") { db in
      // Re-point cooking history rows that reference ingredient-less recipe rows
      // to a same-title recipe that actually has ingredients.
      try db.execute(
        sql: """
          UPDATE cooking_history
          SET recipe_id = (
            SELECT r_good.id
            FROM recipes r_bad
            JOIN recipes r_good
              ON LOWER(TRIM(r_good.title)) = LOWER(TRIM(r_bad.title))
            WHERE r_bad.id = cooking_history.recipe_id
              AND EXISTS(
                SELECT 1
                FROM recipe_ingredients ri_good
                WHERE ri_good.recipe_id = r_good.id
              )
            ORDER BY r_good.id ASC
            LIMIT 1
          )
          WHERE recipe_id IN (
            SELECT r.id
            FROM recipes r
            WHERE NOT EXISTS(
              SELECT 1
              FROM recipe_ingredients ri
              WHERE ri.recipe_id = r.id
            )
          )
            AND EXISTS (
              SELECT 1
              FROM recipes r_bad
              JOIN recipes r_good
                ON LOWER(TRIM(r_good.title)) = LOWER(TRIM(r_bad.title))
              WHERE r_bad.id = cooking_history.recipe_id
                AND EXISTS(
                  SELECT 1
                  FROM recipe_ingredients ri_good
                  WHERE ri_good.recipe_id = r_good.id
                )
            )
          """
      )

      // Remove dangling placeholder recipes that have no ingredients and are
      // no longer referenced by cooking history.
      try db.execute(
        sql: """
          DELETE FROM recipes
          WHERE NOT EXISTS (
            SELECT 1
            FROM recipe_ingredients ri
            WHERE ri.recipe_id = recipes.id
          )
            AND NOT EXISTS (
              SELECT 1
              FROM cooking_history ch
              WHERE ch.recipe_id = recipes.id
            )
          """
      )
    }

    // MARK: - V12: Required onboarding identity fields

    migrator.registerMigration("v12_required_onboarding_identity") { db in
      try db.alter(table: "health_profile") { t in
        t.add(column: "display_name", .text).notNull().defaults(to: "")
        t.add(column: "age", .integer)
      }
    }

    // MARK: - V13: Ingredient favorites for quick-access picker

    migrator.registerMigration("v13_ingredient_favorites") { db in
      try db.create(table: "ingredient_favorites") { t in
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.primaryKey(["ingredient_id"])
      }
    }

    // MARK: - V14: Pantry assumptions + saved winners

    migrator.registerMigration("v14_pantry_assumptions_saved_winners") { db in
      // Pantry staples — ingredients the user always/usually has on hand
      try db.create(table: "pantry_assumptions") { t in
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        t.column("tier", .text).notNull().defaults(to: "only_if_confirmed")
        t.column("added_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.primaryKey(["ingredient_id"])
      }

      // Saved winner flag on cooking history
      try db.alter(table: "cooking_history") { t in
        t.add(column: "is_saved_winner", .integer).notNull().defaults(to: 0)
      }
    }

    // MARK: - V15: Notification rules + freshness opportunities

    migrator.registerMigration("v15_notification_rules_and_opportunities") { db in
      try db.create(table: "notification_rules") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("kind", .text).notNull().unique()
        t.column("enabled", .boolean).notNull().defaults(to: false)
        t.column("hour", .integer).notNull()
        t.column("minute", .integer).notNull()
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(table: "notification_opportunities") { t in
        t.primaryKey("id", .text)
        t.column("kind", .text).notNull()
        t.column("title", .text).notNull()
        t.column("body", .text).notNull()
        t.column("scheduled_at", .datetime).notNull()
        t.column("payload_json", .text).notNull().defaults(to: "{}")
        t.column("source", .text).notNull()
        t.column("status", .text).notNull().defaults(to: "scheduled")
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      try db.create(
        index: "idx_notification_rules_kind",
        on: "notification_rules",
        columns: ["kind"]
      )
      try db.create(
        index: "idx_notification_opportunities_schedule",
        on: "notification_opportunities",
        columns: ["kind", "scheduled_at", "status"]
      )
    }

    try migrator.migrate(db)
  }
}
