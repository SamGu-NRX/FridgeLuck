import Foundation
import FLTaste

/// Parses the app's bundled recipe corpus (`apps/ios/Resources/data.json`)
/// into the typed `RecipeCatalog` the engine ranks over.
///
/// The app schema is positional:
///
/// - `ingredients`: object keyed by integer-string id, value
///   `[name, kcal/100g, protein, carbs, fat, fiber, sugar, sodium,
///   typicalUnit?, storageTip?]`. Only the first six fields feed the taste
///   feature space; sugar, sodium and the hint strings are ignored here.
/// - `recipes`: array of
///   `[id, title, timeMinutes, servings, required[[ingredientId, grams]...],
///   optional[...], instructions, tagBitmask]`.
/// - `tags`: the 12 tag names in bit order; the bitmask is decoded against
///   `CatalogTag` directly, so this loader also validates the tag list.
///
/// Identifier conventions (stable, documented):
///
/// - `IngredientID` is the ingredient **name** (`"chicken"`), not the
///   numeric key. Feature keys then read `ingredient.chicken`, matching
///   Part 1's fixtures and FEATURES.md examples, and stay stable if the
///   numeric keys are renumbered.
/// - `RecipeID` is the decimal string of the catalog's integer id (`"1"`).
public enum CatalogLoader {

    public enum LoaderError: Error, Equatable {
        /// Structurally wrong input: the message names the first problem.
        case malformed(String)
    }

    public static func load(dataJSON: String) throws -> RecipeCatalog {
        guard let data = dataJSON.data(using: .utf8) else {
            throw LoaderError.malformed("input is not UTF-8")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoaderError.malformed("not valid JSON: \(error)")
        }
        guard let object = root as? [String: Any] else {
            throw LoaderError.malformed("top level is not an object")
        }
        guard let rawIngredients = object["ingredients"] as? [String: Any] else {
            throw LoaderError.malformed("missing ingredients object")
        }
        guard let rawRecipes = object["recipes"] as? [Any] else {
            throw LoaderError.malformed("missing recipes array")
        }
        guard let rawTags = object["tags"] as? [String] else {
            throw LoaderError.malformed("missing tags array")
        }
        try validateTagList(rawTags)

        // Numeric id order, so the loader is deterministic regardless of the
        // JSON object's storage order.
        let ingredientIds = rawIngredients.keys.compactMap { Int($0) }.sorted()
        guard ingredientIds.count == rawIngredients.count else {
            throw LoaderError.malformed("ingredient keys must be distinct integer strings")
        }

        var ingredients: [CatalogIngredient] = []
        var namesByID: [Int: String] = [:]
        for id in ingredientIds {
            guard let fields = rawIngredients[String(id)] as? [Any] else {
                throw LoaderError.malformed("ingredient \(id) is not an array")
            }
            guard fields.count >= 6, let name = fields[0] as? String,
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw LoaderError.malformed("ingredient \(id) needs [name, cal, protein, carbs, fat, fiber, ...]")
            }
            let numbers = try parseNumbers(fields[1...5], context: "ingredient \(id) (\(name))")
            guard namesByID[id] == nil else {
                throw LoaderError.malformed("duplicate ingredient id \(id)")
            }
            namesByID[id] = name
            ingredients.append(
                CatalogIngredient(
                    id: IngredientID(name)!,
                    name: name,
                    caloriesPer100g: numbers[0],
                    proteinPer100g: numbers[1],
                    carbsPer100g: numbers[2],
                    fatPer100g: numbers[3],
                    fiberPer100g: numbers[4]))
        }

        var recipes: [CatalogRecipe] = []
        for raw in rawRecipes {
            guard let fields = raw as? [Any], fields.count >= 8 else {
                throw LoaderError.malformed("recipe row needs 8 fields")
            }
            let idNumber = fields[0] as? Int ?? (fields[0] as? String).flatMap(Int.init)
            guard let id = idNumber else {
                throw LoaderError.malformed("recipe id must be an integer")
            }
            guard let title = fields[1] as? String, let time = fields[2] as? Int,
                let servings = fields[3] as? Int, servings >= 1,
                let instructions = fields[6] as? String, let bitmask = fields[7] as? Int
            else {
                throw LoaderError.malformed("recipe \(id) has a wrong-typed field")
            }
            let required = try parseUses(fields[4], namesByID: namesByID, context: "recipe \(id) required")
            let optional = try parseUses(fields[5], namesByID: namesByID, context: "recipe \(id) optional")
            recipes.append(
                CatalogRecipe(
                    id: RecipeID(String(id))!,
                    title: title,
                    timeMinutes: time,
                    servings: servings,
                    requiredIngredients: required,
                    optionalIngredients: optional,
                    instructions: instructions,
                    tagBitmask: bitmask))
        }
        return RecipeCatalog(ingredients: ingredients, recipes: recipes)
    }

    /// The catalog's 12 tags, positionally. Accepts the corpus's snake_case
    /// spelling (what Part 1's `CatalogTag.featureValue` returns, e.g.
    /// `high_protein`) or the Swift case name, so a corpus edit can't
    /// silently decode a different bitmask than the app's.
    private static func validateTagList(_ tags: [String]) throws {
        guard tags.count == CatalogTag.allCases.count else {
            throw LoaderError.malformed(
                "tags array does not match the 12 CatalogTag names in bit order")
        }
        for (tag, raw) in zip(CatalogTag.allCases, tags) {
            let accepted = [tag.featureValue, String(describing: tag)]
            guard accepted.contains(where: { $0.caseInsensitiveCompare(raw) == .orderedSame })
            else {
                throw LoaderError.malformed(
                    "tags array does not match the 12 CatalogTag names in bit order")
            }
        }
    }

    private static func parseNumbers(
        _ values: ArraySlice<Any>, context: String
    ) throws -> [Double] {
        var out: [Double] = []
        for value in values {
            if let n = value as? Int { out.append(Double(n)) }
            else if let n = value as? Double { out.append(n) }
            else if let n = value as? NSNumber { out.append(n.doubleValue) }
            else { throw LoaderError.malformed("\(context): expected a number") }
        }
        return out
    }

    private static func parseUses(
        _ raw: Any, namesByID: [Int: String], context: String
    ) throws -> [CatalogRecipe.IngredientUse] {
        guard let rows = raw as? [Any] else {
            throw LoaderError.malformed("\(context): expected an array of [ingredientId, grams]")
        }
        var uses: [CatalogRecipe.IngredientUse] = []
        for row in rows {
            guard let pair = row as? [Any], pair.count == 2,
                let ingredientId = pair[0] as? Int, let grams = (pair[1] as? NSNumber)?.doubleValue,
                let name = namesByID[ingredientId]
            else {
                throw LoaderError.malformed("\(context): bad use row or unknown ingredient id")
            }
            uses.append(CatalogRecipe.IngredientUse(id: IngredientID(name)!, grams: grams))
        }
        return uses
    }
}
