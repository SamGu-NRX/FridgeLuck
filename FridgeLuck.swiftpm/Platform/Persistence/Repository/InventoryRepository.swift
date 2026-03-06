import Foundation
import GRDB

/// Persists smart-fridge inventory lots, aggregate snapshots, and audit events.
/// Quantity units are grams so nutrition and inventory math stay aligned.
final class InventoryRepository: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - Inbound Inventory

  @discardableResult
  func addLot(
    ingredientId: Int64,
    quantityGrams: Double,
    location: InventoryStorageLocation,
    confidenceScore: Double,
    source: InventoryLotSource,
    acquiredAt: Date = Date(),
    expiresAt: Date? = nil,
    reason: String? = nil,
    sourceRef: String? = nil
  ) throws -> Int64 {
    let safeQuantity = max(0, quantityGrams)
    let safeConfidence = max(0, min(confidenceScore, 1.0))

    return try db.write { db in
      let resolvedExpiry: Date?
      if let expiresAt {
        resolvedExpiry = expiresAt
      } else {
        resolvedExpiry = try deriveExpiryDate(
          db: db,
          ingredientId: ingredientId,
          location: location,
          acquiredAt: acquiredAt
        )
      }

      try db.execute(
        sql: """
          INSERT INTO inventory_lots (
            ingredient_id,
            quantity_grams,
            remaining_grams,
            storage_location,
            confidence_score,
            source,
            acquired_at,
            expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          ingredientId,
          safeQuantity,
          safeQuantity,
          location.rawValue,
          safeConfidence,
          source.rawValue,
          acquiredAt,
          resolvedExpiry,
        ]
      )

      let lotID = db.lastInsertedRowID

      try insertEvent(
        db: db,
        ingredientId: ingredientId,
        lotId: lotID,
        eventType: .add,
        quantityDeltaGrams: safeQuantity,
        confidenceScore: safeConfidence,
        reason: reason,
        sourceRef: sourceRef
      )

      try refreshInventoryItem(db: db, ingredientId: ingredientId)
      return lotID
    }
  }

  func upsertShelfLifeProfile(
    ingredientId: Int64,
    fridgeDays: Int?,
    pantryDays: Int?,
    freezerDays: Int?
  ) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredient_shelf_life_profiles (
            ingredient_id,
            fridge_days,
            pantry_days,
            freezer_days,
            updated_at
          )
          VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
          ON CONFLICT(ingredient_id) DO UPDATE SET
            fridge_days = excluded.fridge_days,
            pantry_days = excluded.pantry_days,
            freezer_days = excluded.freezer_days,
            updated_at = CURRENT_TIMESTAMP
          """,
        arguments: [ingredientId, fridgeDays, pantryDays, freezerDays]
      )
    }
  }

  // MARK: - Consumption (Cooking + Reverse Scan Finalization)

  func applyConsumption(
    recipeId: Int64,
    servingsConsumed: Int,
    sourceRef: String? = nil
  ) throws -> [InventoryConsumptionResult] {
    let safeServingsConsumed = max(0, servingsConsumed)
    guard safeServingsConsumed > 0 else { return [] }

    return try db.write { db in
      try applyConsumption(
        in: db,
        recipeId: recipeId,
        servingsConsumed: safeServingsConsumed,
        sourceRef: sourceRef
      )
    }
  }

  /// Transaction-scoped inventory consumption used by higher-level services that
  /// compose cooking-history and inventory mutations in one write transaction.
  func applyConsumption(
    in db: Database,
    recipeId: Int64,
    servingsConsumed: Int,
    sourceRef: String? = nil
  ) throws -> [InventoryConsumptionResult] {
    let safeServingsConsumed = max(0, servingsConsumed)
    guard safeServingsConsumed > 0 else { return [] }

    guard
      let recipeServings = try Int.fetchOne(
        db,
        sql: "SELECT servings FROM recipes WHERE id = ?",
        arguments: [recipeId]
      )
    else {
      return []
    }

    let servingFactor = Double(safeServingsConsumed) / Double(max(recipeServings, 1))
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT ingredient_id, quantity_grams
        FROM recipe_ingredients
        WHERE recipe_id = ? AND is_required = 1
        """,
      arguments: [recipeId]
    )

    var results: [InventoryConsumptionResult] = []
    for row in rows {
      let ingredientId: Int64 = row["ingredient_id"]
      let baseGrams: Double = row["quantity_grams"]
      let requiredGrams = max(0, baseGrams * servingFactor)

      let consumedGrams = try consumeIngredientLots(
        db: db,
        ingredientId: ingredientId,
        requiredGrams: requiredGrams,
        sourceRef: sourceRef ?? "recipe:\(recipeId)"
      )

      results.append(
        InventoryConsumptionResult(
          ingredientId: ingredientId,
          requestedGrams: requiredGrams,
          consumedGrams: consumedGrams,
          shortfallGrams: max(0, requiredGrams - consumedGrams)
        )
      )
    }

    return results
  }

  // MARK: - Read Models

  func totalRemainingGrams(for ingredientId: Int64) throws -> Double {
    try db.read { db in
      try Double.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(remaining_grams), 0)
          FROM inventory_lots
          WHERE ingredient_id = ? AND remaining_grams > 0
          """,
        arguments: [ingredientId]
      ) ?? 0
    }
  }

  func useSoonSuggestions(withinDays: Int = 3, limit: Int = 12) throws
    -> [InventoryUseSoonSuggestion]
  {
    let safeDays = max(1, withinDays)
    let safeLimit = max(1, limit)
    let modifier = "+\(safeDays) days"
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    return try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT
            il.ingredient_id AS ingredient_id,
            i.name AS ingredient_name,
            SUM(il.remaining_grams) AS remaining_grams,
            MIN(il.expires_at) AS earliest_expires_at,
            AVG(il.confidence_score) AS avg_confidence_score
          FROM inventory_lots il
          JOIN ingredients i ON i.id = il.ingredient_id
          WHERE il.remaining_grams > 0
            AND il.expires_at IS NOT NULL
            AND datetime(il.expires_at) >= datetime('now')
            AND datetime(il.expires_at) <= datetime('now', ?)
          GROUP BY il.ingredient_id, i.name
          ORDER BY datetime(earliest_expires_at) ASC, remaining_grams DESC
          LIMIT ?
          """,
        arguments: [modifier, safeLimit]
      )

      return rows.compactMap { row in
        guard
          let ingredientId: Int64 = row["ingredient_id"],
          let ingredientName: String = row["ingredient_name"],
          let remainingGrams: Double = row["remaining_grams"],
          let earliestExpiresAt: Date = row["earliest_expires_at"]
        else {
          return nil
        }

        let expiryDay = calendar.startOfDay(for: earliestExpiresAt)
        let daysRemaining = calendar.dateComponents([.day], from: today, to: expiryDay).day ?? 0
        let confidence: Double = row["avg_confidence_score"] as? Double ?? 1.0

        return InventoryUseSoonSuggestion(
          ingredientId: ingredientId,
          ingredientName: ingredientName.replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized,
          remainingGrams: remainingGrams,
          earliestExpiresAt: earliestExpiresAt,
          daysRemaining: daysRemaining,
          confidenceScore: max(0, min(confidence, 1.0))
        )
      }
    }
  }

  func recentEvents(limit: Int = 50) throws -> [InventoryEvent] {
    let safeLimit = max(1, limit)
    return try db.read { db in
      try InventoryEvent.fetchAll(
        db,
        sql: """
          SELECT *
          FROM inventory_events
          ORDER BY created_at DESC, id DESC
          LIMIT ?
          """,
        arguments: [safeLimit]
      )
    }
  }

  func hasEvent(eventType: InventoryEventType, sourceRef: String) throws -> Bool {
    let normalizedRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRef.isEmpty else { return false }

    return try db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1
            FROM inventory_events
            WHERE event_type = ?
              AND source_ref = ?
            LIMIT 1
          )
          """,
        arguments: [eventType.rawValue, normalizedRef]
      ) ?? false
    }
  }

  // MARK: - Internal helpers

  private func consumeIngredientLots(
    db: Database,
    ingredientId: Int64,
    requiredGrams: Double,
    sourceRef: String
  ) throws -> Double {
    var remainingToConsume = max(0, requiredGrams)
    guard remainingToConsume > 0 else { return 0 }

    let lots = try Row.fetchAll(
      db,
      sql: """
        SELECT id, remaining_grams, confidence_score
        FROM inventory_lots
        WHERE ingredient_id = ? AND remaining_grams > 0
        ORDER BY
          CASE WHEN expires_at IS NULL THEN 1 ELSE 0 END ASC,
          datetime(expires_at) ASC,
          datetime(acquired_at) ASC,
          id ASC
        """,
      arguments: [ingredientId]
    )

    var consumedTotal = 0.0
    for row in lots {
      guard remainingToConsume > 0 else { break }
      guard
        let lotID: Int64 = row["id"],
        let lotRemaining: Double = row["remaining_grams"]
      else {
        continue
      }
      let take = min(remainingToConsume, max(0, lotRemaining))
      guard take > 0 else { continue }

      let newRemaining = max(0, lotRemaining - take)
      try db.execute(
        sql: """
          UPDATE inventory_lots
          SET remaining_grams = ?, updated_at = CURRENT_TIMESTAMP
          WHERE id = ?
          """,
        arguments: [newRemaining, lotID]
      )

      let confidence = max(0, min((row["confidence_score"] as? Double) ?? 1.0, 1.0))
      try insertEvent(
        db: db,
        ingredientId: ingredientId,
        lotId: lotID,
        eventType: .consume,
        quantityDeltaGrams: -take,
        confidenceScore: confidence,
        reason: "Cooked meal consumption",
        sourceRef: sourceRef
      )

      consumedTotal += take
      remainingToConsume -= take
    }

    try refreshInventoryItem(db: db, ingredientId: ingredientId)
    return consumedTotal
  }

  private func deriveExpiryDate(
    db: Database,
    ingredientId: Int64,
    location: InventoryStorageLocation,
    acquiredAt: Date
  ) throws -> Date? {
    let days = try shelfLifeDays(db: db, ingredientId: ingredientId, location: location)
    guard let days, days > 0 else { return nil }
    return Calendar.current.date(byAdding: .day, value: days, to: acquiredAt)
  }

  private func shelfLifeDays(
    db: Database,
    ingredientId: Int64,
    location: InventoryStorageLocation
  ) throws -> Int? {
    if let row = try Row.fetchOne(
      db,
      sql: """
        SELECT fridge_days, pantry_days, freezer_days
        FROM ingredient_shelf_life_profiles
        WHERE ingredient_id = ?
        """,
      arguments: [ingredientId]
    ) {
      switch location {
      case .fridge:
        if let days: Int = row["fridge_days"] { return days }
      case .pantry:
        if let days: Int = row["pantry_days"] { return days }
      case .freezer:
        if let days: Int = row["freezer_days"] { return days }
      case .unknown:
        break
      }
    }

    switch location {
    case .fridge: return 7
    case .pantry: return 30
    case .freezer: return 90
    case .unknown: return nil
    }
  }

  private func insertEvent(
    db: Database,
    ingredientId: Int64,
    lotId: Int64?,
    eventType: InventoryEventType,
    quantityDeltaGrams: Double,
    confidenceScore: Double,
    reason: String?,
    sourceRef: String?
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO inventory_events (
          ingredient_id,
          lot_id,
          event_type,
          quantity_delta_grams,
          confidence_score,
          reason,
          source_ref
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        ingredientId,
        lotId,
        eventType.rawValue,
        quantityDeltaGrams,
        confidenceScore,
        reason,
        sourceRef,
      ]
    )
  }

  private func refreshInventoryItem(db: Database, ingredientId: Int64) throws {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(remaining_grams), 0) AS total_remaining_grams,
          COALESCE(
            SUM(remaining_grams * confidence_score) / NULLIF(SUM(remaining_grams), 0),
            1.0
          ) AS avg_confidence
        FROM inventory_lots
        WHERE ingredient_id = ? AND remaining_grams > 0
        """,
      arguments: [ingredientId]
    )

    let totalRemaining = max(0, row?["total_remaining_grams"] as? Double ?? 0)
    let avgConfidence = max(0, min(row?["avg_confidence"] as? Double ?? 1.0, 1.0))

    try db.execute(
      sql: """
        INSERT INTO inventory_items (
          ingredient_id,
          total_remaining_grams,
          average_confidence_score,
          last_updated_at
        ) VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(ingredient_id) DO UPDATE SET
          total_remaining_grams = excluded.total_remaining_grams,
          average_confidence_score = excluded.average_confidence_score,
          last_updated_at = CURRENT_TIMESTAMP
        """,
      arguments: [ingredientId, totalRemaining, avgConfidence]
    )
  }
}
