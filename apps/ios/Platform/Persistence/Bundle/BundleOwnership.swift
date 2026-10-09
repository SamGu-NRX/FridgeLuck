import CryptoKit
import Foundation

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
}
