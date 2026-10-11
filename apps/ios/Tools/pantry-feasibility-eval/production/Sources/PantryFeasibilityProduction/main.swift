import Foundation
import GRDB

// Live production replay: runs the actual RecipeRepository.findMakeable /
// findNearMatch over every (state, recipe) pair in the frozen corpus, using
// one real migrated in-memory database per state. Results are JSONL rows of
// the makeable and near-match recipe ID sets production returns.

// MARK: - Corpus decoding

struct SnapshotRecipe: Decodable {
    let required: [[Double]]
    let optional: [[Double]]
    let tags: Int
    let time_minutes: Int
    let title: String
}

// Provenance values are heterogeneous (strings and numbers) and unused here.
struct ProvenanceValue: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}

struct Snapshot: Decodable {
    let ingredient_names: [String: String]
    let provenance: [String: ProvenanceValue]
    let recipes: [String: SnapshotRecipe]
}

struct ProfileFile: Decodable {
    let allergen_groups: [String]
    let allergen_ingredient_ids: [Int]
    let allergen_preferences_version: Int
    let diet: String?
    let goal: String?
}

struct LotFile: Decodable {
    let ingredient_id: Int
    let is_estimate: Bool
    let known_grams: Double?
}

struct StateFile: Decodable {
    let state_id: Int
    let family: String
    let available_ids: [Int]
    let profile: ProfileFile
    let pantry: [LotFile]
}

// MARK: - JSON helpers

func jsonString(_ values: [Int]) -> String {
    let array = values.map { String($0) }.joined(separator: ",")
    return "[\(array)]"
}

func jsonString(_ values: [String]) -> String {
    let quoted = values.map { "\"" + $0 + "\"" }.joined(separator: ",")
    return "[\(quoted)]"
}

// MARK: - Output row

struct ReplayRow: Encodable {
    let state_id: Int
    let family: String
    let makeable_ids: [Int64]
    let near_match_ids: [Int64]
}

// MARK: - Replay

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var corpusDir = URL(fileURLWithPath: "runs")
var outputPath = URL(fileURLWithPath: "production_replay.jsonl")

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--corpus-dir":
        guard let value = args.first else { fail("--corpus-dir needs a value") }
        args.removeFirst()
        corpusDir = URL(fileURLWithPath: value)
    case "--output":
        guard let value = args.first else { fail("--output needs a value") }
        args.removeFirst()
        outputPath = URL(fileURLWithPath: value)
    default:
        fail("unknown argument: \(arg)")
    }
}

let decoder = JSONDecoder()
let snapshot: Snapshot
do {
    snapshot = try decoder.decode(
        Snapshot.self,
        from: Data(contentsOf: corpusDir.appendingPathComponent("catalog_snapshot.json")))
} catch {
    fail("cannot decode catalog snapshot: \(error)")
}

var states: [StateFile] = []
do {
    let data = try Data(
        contentsOf: corpusDir.appendingPathComponent("states.jsonl"))
    for line in data.split(separator: 0x0A) where !line.isEmpty {
        states.append(try decoder.decode(StateFile.self, from: Data(line)))
    }
} catch {
    fail("cannot decode corpus states: \(error)")
}

let catalog = snapshot.recipes.compactMap { key, recipe -> (Int64, SnapshotRecipe)? in
    guard let id = Int64(key) else { return nil }
    return (id, recipe)
}.sorted { $0.0 < $1.0 }

let ingredientNames = snapshot.ingredient_names
let startedAt = Date()

_ = FileManager.default.createFile(atPath: outputPath.path, contents: nil)
let output: FileHandle
do {
    output = try FileHandle(forWritingTo: outputPath)
} catch {
    fail("cannot open output: \(error)")
}

for state in states {
    // One real migrated database per state — the same migrations the app runs.
    let dbQueue: DatabaseQueue
    do {
        dbQueue = try DatabaseQueue()
        try DatabaseMigrations.migrate(dbQueue)
    } catch {
        fail("state \(state.state_id): migration failed: \(error)")
    }

    do {
        try dbQueue.write { db in
            // Bundled core ingredients (IDs 1...50). Macro values do not
            // participate in makeability; the snapshot carries no nutrition.
            for (key, name) in ingredientNames {
                guard let id = Int64(key) else { continue }
                try db.execute(
                    sql: """
                      INSERT INTO ingredients
                          (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
                      VALUES (?, ?, 0, 0, 0, 0, 0, 0, 0)
                      """,
                    arguments: [id, name])
            }

            for (recipeId, recipe) in catalog {
                try db.execute(
                    sql: """
                      INSERT INTO recipes
                          (id, title, time_minutes, servings, instructions, tags, source)
                      VALUES (?, ?, ?, 2, '', ?, 'bundled')
                      """,
                    arguments: [recipeId, recipe.title, recipe.time_minutes, recipe.tags])
                for pair in recipe.required {
                    try db.execute(
                        sql: """
                          INSERT INTO recipe_ingredients
                              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
                          VALUES (?, ?, 1, ?, '')
                          """,
                        arguments: [recipeId, Int64(pair[0]), pair[1]])
                }
                for pair in recipe.optional {
                    try db.execute(
                        sql: """
                          INSERT INTO recipe_ingredients
                              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
                          VALUES (?, ?, 0, ?, '')
                          """,
                        arguments: [recipeId, Int64(pair[0]), pair[1]])
                }
            }

            // Health profile: the diet is stored as a dietary restriction ID,
            // which is how production persists it.
            let dietRestrictions = state.profile.diet.map { [$0] } ?? []
            var profile = HealthProfile(
                displayName: "Replay",
                age: nil,
                goal: HealthGoal(rawValue: state.profile.goal ?? "") ?? .general,
                dailyCalories: nil,
                proteinPct: 0.25,
                carbsPct: 0.45,
                fatPct: 0.30,
                dietaryRestrictions: jsonString(dietRestrictions),
                allergenIngredientIds: jsonString(state.profile.allergen_ingredient_ids),
                allergenSelectedGroups: jsonString(state.profile.allergen_groups),
                allergenPreferencesVersion: state.profile.allergen_preferences_version)
            try profile.insert(db)

            // Pantry lots: unknown amounts land as estimate lots, exactly how
            // photo-intake lots persist (v16 quantity_is_estimate).
            for lot in state.pantry {
                let grams = lot.known_grams ?? 0
                try db.execute(
                    sql: """
                      INSERT INTO inventory_lots
                          (ingredient_id, quantity_grams, remaining_grams, quantity_is_estimate)
                      VALUES (?, ?, ?, ?)
                      """,
                    arguments: [
                        Int64(lot.ingredient_id), grams, grams,
                        lot.is_estimate || lot.known_grams == nil,
                    ])
            }
        }
    } catch {
        fail("state \(state.state_id): seeding failed: \(error)")
    }

    // Load the profile back through the real record path.
    let profile: HealthProfile
    let availableIds = Set(state.available_ids.map { Int64($0) })
    do {
        profile = try dbQueue.read { db in
            guard let loaded = try HealthProfile.fetchOne(db, key: 1) else {
                fail("state \(state.state_id): profile row missing after insert")
            }
            return loaded
        }

        let nutritionService = NutritionService(db: dbQueue)
        let repository = RecipeRepository(
            db: dbQueue,
            nutritionService: nutritionService,
            healthScoringService: HealthScoringService(
                nutritionService: nutritionService, db: dbQueue),
            personalizationService: PersonalizationService(db: dbQueue))

        let makeable = try repository.findMakeable(
            with: availableIds, profile: profile, limit: 100_000)
        let nearMatch = try repository.findNearMatch(
            with: availableIds, profile: profile, maxMissingRequired: 3, limit: 100_000)

        let makeableIds = makeable.compactMap { $0.recipe.id }.sorted()
        let nearMatchIds = nearMatch.compactMap { $0.recipe.id }.sorted()
        let row = ReplayRow(
            state_id: state.state_id,
            family: state.family,
            makeable_ids: makeableIds,
            near_match_ids: nearMatchIds)
        let line = try JSONEncoder().encode(row)
        output.write(Data(line))
        output.write(Data("\n".utf8))
    } catch {
        fail("state \(state.state_id): replay failed: \(error)")
    }
}

try output.close()
let elapsed = Date().timeIntervalSince(startedAt)
let summary = "replayed \(states.count) states over \(catalog.count) recipes in "
    + String(format: "%.1fs", elapsed) + " -> \(outputPath.path)\n"
FileHandle.standardError.write(Data(summary.utf8))
