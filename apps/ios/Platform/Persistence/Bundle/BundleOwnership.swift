import CryptoKit
import Foundation
import GRDB

/// Namespaced ownership keys tying installed rows to the bundle entries they came from.
///
/// Hydration history left installed recipes with autoincrement ids that no longer match
/// the bundle's own recipe ids, and the USDA catalog import dropped the source fdc ids.
/// Ownership keys restore a stable identity that survives bundle content changes: the
/// numeric id inside the key is the bundle entry's own id (data.json recipe/ingredient
/// id, or the catalog row's fdc id), namespaced by the system that assigned it so the
/// two id spaces cannot collide.
enum BundleOwnership {
  static func recipeKey(bundleRecipeId: Int) -> String {
    "fridgeluck.bundle.recipe/\(bundleRecipeId)"
  }

  static func ingredientKey(bundleIngredientId: Int) -> String {
    "fridgeluck.bundle.ingredient/\(bundleIngredientId)"
  }

  static func usdaIngredientKey(fdcId: Int64) -> String {
    "usda.fdc/\(fdcId)"
  }
}

/// Canonical content hashes for bundle-written rows.
///
/// A row's hash covers exactly the columns the bundle last wrote, in a fixed order,
/// over a stable text encoding. It deliberately excludes the row id, created_at, and
/// anything the user controls through other tables (favorites, history, inventory):
/// none of those say anything about whether the bundle's own content is current on
/// the row. The hash exists so a refresh can tell "this row still carries what the
/// bundle wrote" apart from "someone or something changed this row since".
enum CanonicalHash {
  static let formatTag = "fridgeluck.canonical/v1"

  /// SHA-256 hex over ordered named fields. Field order is part of the contract:
  /// callers must keep it stable per entity kind.
  static func hash(fields: [(name: String, value: String?)]) -> String {
    var payload = formatTag
    for field in fields {
      payload += "\n\u{1F}\(field.name)=\(field.value ?? "\u{0}nil")"
    }
    let digest = SHA256.hash(data: Data(payload.utf8))
    return digest.map { Self.hexByte($0) }.joined()
  }

  /// Swift's Double description is the shortest string that round-trips the exact
  /// bit pattern, so the same stored REAL always canonicalizes to the same text.
  static func real(_ value: Double) -> String {
    String(value)
  }

  static func integer(_ value: Int) -> String {
    String(value)
  }

  static func bool(_ value: Bool) -> String {
    value ? "1" : "0"
  }

  private static func hexByte(_ byte: UInt8) -> String {
    let digits = "0123456789abcdef"
    let high = Int(byte) / 16
    let low = Int(byte) % 16
    return "\(digits[digits.index(digits.startIndex, offsetBy: high)])"
      + "\(digits[digits.index(digits.startIndex, offsetBy: low)])"
  }
}

/// Projects bundle payloads into the exact column values each writer produces, so a
/// payload-side hash matches the hash an installed row would carry if it were written
/// by that writer. The loaders write a fixed set of columns per provenance:
///
/// - data.json recipes: title, time, servings, instructions, tags, source='bundled'
/// - data.json ingredients (first-launch load): nutrition, unit, tip; educational
///   fields (pairs_with, notes) and display metadata are NOT written today, so they
///   canonicalize as nil for this provenance.
/// - USDA catalog ingredients: nutrition, notes, display metadata (description
///   COALESCEd to ''); unit, tip, and pairs_with are written NULL.
enum BundleRowProjection {
  static func recipeFields(_ raw: RecipeArray) -> [(name: String, value: String?)] {
    [
      ("title", raw.title),
      ("time_minutes", CanonicalHash.integer(raw.timeMinutes)),
      ("servings", CanonicalHash.integer(raw.servings)),
      ("instructions", raw.instructions),
      ("tags", CanonicalHash.integer(raw.tagBitmask)),
      ("source", "bundled"),
    ]
  }

  static func dataJsonIngredientFields(_ raw: IngredientArray) -> [(name: String, value: String?)] {
    [
      ("name", raw.name),
      ("calories", CanonicalHash.real(raw.calories)),
      ("protein", CanonicalHash.real(raw.protein)),
      ("carbs", CanonicalHash.real(raw.carbs)),
      ("fat", CanonicalHash.real(raw.fat)),
      ("fiber", CanonicalHash.real(raw.fiber)),
      ("sugar", CanonicalHash.real(raw.sugar)),
      ("sodium", CanonicalHash.real(raw.sodium)),
      ("typical_unit", raw.typicalUnit),
      ("storage_tip", raw.storageTip),
      ("pairs_with", nil),
      ("notes", nil),
      ("description", nil),
      ("category_label", nil),
      ("sprite_group", nil),
      ("sprite_key", nil),
    ]
  }

  static func catalogIngredientFields(_ raw: LegacyCatalogIngredient) -> [(name: String, value: String?)] {
    [
      ("name", raw.name),
      ("calories", CanonicalHash.real(raw.calories)),
      ("protein", CanonicalHash.real(raw.protein)),
      ("carbs", CanonicalHash.real(raw.carbs)),
      ("fat", CanonicalHash.real(raw.fat)),
      ("fiber", CanonicalHash.real(raw.fiber)),
      ("sugar", CanonicalHash.real(raw.sugar)),
      ("sodium", CanonicalHash.real(raw.sodium)),
      ("typical_unit", nil),
      ("storage_tip", nil),
      ("pairs_with", nil),
      ("notes", raw.notes),
      ("description", raw.description),
      ("category_label", raw.categoryLabel),
      ("sprite_group", raw.spriteGroup),
      ("sprite_key", raw.spriteKey),
    ]
  }

  // MARK: - Row-side projections

  /// Selects which writer's column set to read a row back with. The two ingredient
  /// projections differ in which columns each writer produced, so the choice must
  /// follow the row's provenance, not trial and error.
  enum RowSource {
    case recipe
    case dataJsonIngredient
    case catalogIngredient
  }

  /// Reads a row with the named projection. Field names, order, and canonical
  /// encodings are identical to the payload-side functions above — that is the
  /// invariant that lets a row hash be compared against a payload hash.
  static func rowFields(_ row: Row, projection: RowSource) -> [(name: String, value: String?)] {
    switch projection {
    case .recipe:
      return [
        ("title", row["title"]),
        ("time_minutes", CanonicalHash.integer(row["time_minutes"] ?? 0)),
        ("servings", CanonicalHash.integer(row["servings"] ?? 1)),
        ("instructions", row["instructions"]),
        ("tags", CanonicalHash.integer(row["tags"] ?? 0)),
        ("source", row["source"] ?? "bundled"),
      ]
    case .dataJsonIngredient:
      return [
        ("name", row["name"]),
        ("calories", CanonicalHash.real(row["calories"] ?? 0)),
        ("protein", CanonicalHash.real(row["protein"] ?? 0)),
        ("carbs", CanonicalHash.real(row["carbs"] ?? 0)),
        ("fat", CanonicalHash.real(row["fat"] ?? 0)),
        ("fiber", CanonicalHash.real(row["fiber"] ?? 0)),
        ("sugar", CanonicalHash.real(row["sugar"] ?? 0)),
        ("sodium", CanonicalHash.real(row["sodium"] ?? 0)),
        ("typical_unit", row["typical_unit"]),
        ("storage_tip", row["storage_tip"]),
        ("pairs_with", nil),
        ("notes", nil),
        ("description", nil),
        ("category_label", nil),
        ("sprite_group", nil),
        ("sprite_key", nil),
      ]
    case .catalogIngredient:
      return [
        ("name", row["name"]),
        ("calories", CanonicalHash.real(row["calories"] ?? 0)),
        ("protein", CanonicalHash.real(row["protein"] ?? 0)),
        ("carbs", CanonicalHash.real(row["carbs"] ?? 0)),
        ("fat", CanonicalHash.real(row["fat"] ?? 0)),
        ("fiber", CanonicalHash.real(row["fiber"] ?? 0)),
        ("sugar", CanonicalHash.real(row["sugar"] ?? 0)),
        ("sodium", CanonicalHash.real(row["sodium"] ?? 0)),
        ("typical_unit", nil),
        ("storage_tip", nil),
        ("pairs_with", nil),
        ("notes", row["notes"]),
        ("description", row["description"] ?? ""),
        ("category_label", row["category_label"] ?? ""),
        ("sprite_group", row["sprite_group"] ?? ""),
        ("sprite_key", row["sprite_key"] ?? ""),
      ]
    }
  }
}
