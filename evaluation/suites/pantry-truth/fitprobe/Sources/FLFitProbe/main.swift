// Suite A (pantry-truth) — production fit probe.
//
// Compiles and runs the production pure-logic fit subset (RecipeRepository,
// scoring, services, domain models, RecommendationPolicy) against the same
// GRDB the app vendors, then replays audit jobs through the REAL production
// calls. Job file on argv[1], results JSON written to argv[2].
//
// Composition per pair mirrors RecommendationEngine.findRecipes (apps/ios/
// FeatureLogic/Recommendation/RecommendationEngine.swift): the pantry's
// ingredient IDs pass through RecommendationPolicy.effectiveIngredientIDs,
// then findMakeable(limit: 20) and findNearMatch(maxMissingRequired: 1,
// limit: nearMatchLimit(hasExactMatches:)) run; if both come back empty the
// near-match search widens (shouldWidenNearMatchSearch) to
// maxMissingRequired: 2, limit: 20. A pair's recipe is "rendered" when it
// appears in the exact or near-match section a user would see.
//
// Input mapping note (documented in the suite README): production's
// AppDependencies.swift:137-139 derives availableIds as
// `Set(inventoryRepository.fetchAllActiveItems().map(\.ingredientId))` —
// inventory lots only (remaining_grams > 0); pantry assumptions never join
// the recommendation fit. The suite therefore passes exactly the ingredient
// IDs that have physical lots.

@testable import FLFitProduction
import Foundation
import GRDB

struct PairJob: Codable {
  var pairId: String
  var recipeId: Int64
  var availableIds: [Int64]
}

struct PlanJob: Codable {
  var planId: String
  var recipeIds: [Int64]
  var availableIds: [Int64]
}

struct ProbeJob: Codable {
  var ingredients: [[CodableValue]] // [id, calories, protein, carbs, fat]
  var ingredientNames: [[CodableValue]] // [id, name, typical_unit, storage_tip]
  var recipes: [[CodableValue]]
  var pairs: [PairJob]
  var plans: [PlanJob]
}

// The corpus uses heterogeneous arrays (numbers and strings); decode leniently.
enum CodableValue: Codable {
  case double(Double)
  case string(String)
  case array([CodableValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let d = try? container.decode(Double.self) {
      self = .double(d)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([CodableValue].self) {
      self = .array(a)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .double(let d): try container.encode(d)
    case .string(let s): try container.encode(s)
    case .array(let a): try container.encode(a)
    }
  }

  var doubleValue: Double? {
    if case .double(let d) = self { return d }
    return nil
  }

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var arrayValue: [CodableValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  var int64Value: Int64? {
    guard let d = doubleValue else { return nil }
    return Int64(d)
  }
}

struct PairRow: Codable {
  var pairId: String
  var found: Bool
  var tier: String?
  var matchedRequired: Int?
  var totalRequired: Int?
  var matchedOptional: Int?
  var missingRequiredCount: Int?
  var missingIngredientIds: [Int64]
  var rankingReasons: [String]
}

struct PlanRecipeRow: Codable {
  var planId: String
  var recipeId: Int64
  var found: Bool
  var tier: String?
  var matchedRequired: Int?
  var totalRequired: Int?
  var missingRequiredCount: Int?
  var rankingReasons: [String]
}

struct ProbeOutput: Codable {
  var probe: String
  var pairs: [PairRow]
  var plans: [PlanRecipeRow]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("FLFitProbe error: \(message)\n".utf8))
  exit(2)
}

@main
struct Probe {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else {
      fail("usage: FLFitProbe <job.json> <out.json>")
    }
    let jobURL = URL(fileURLWithPath: args[1])
    let outURL = URL(fileURLWithPath: args[2])

    let jobData = try Data(contentsOf: jobURL)
    let job = try JSONDecoder().decode(ProbeJob.self, from: jobData)

    let db = try DatabaseQueue(path: ":memory:")
    try DatabaseMigrations.migrate(db)
    try seed(db: db, job: job)

    let nutrition = NutritionService(db: db)
    let repo = RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db)
    )
    let profile = try HealthScoringService(nutritionService: nutrition, db: db)
      .fetchHealthProfile()

    // Production composition, applied per pair.
    var pairRows: [PairRow] = []
    for pair in job.pairs {
      let effective = RecommendationPolicy.effectiveIngredientIDs(from: Set(pair.availableIds))
      let exact = try repo.findMakeable(with: effective, profile: profile, limit: 20)
      var near = try repo.findNearMatch(
        with: effective, profile: profile,
        maxMissingRequired: 1,
        limit: RecommendationPolicy.nearMatchLimit(hasExactMatches: !exact.isEmpty))
      if RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: exact.count, nearMatchCount: near.count) {
        near = try repo.findNearMatch(
          with: effective, profile: profile, maxMissingRequired: 2, limit: 20)
      }
      let all = exact + near
      let scored = all.first { $0.recipe.id == pair.recipeId }
      pairRows.append(PairRow(
        pairId: pair.pairId,
        found: scored != nil,
        tier: scored.map { $0.matchTier == .exact ? "exact" : "nearMatch" },
        matchedRequired: scored?.matchedRequired,
        totalRequired: scored?.totalRequired,
        matchedOptional: scored?.matchedOptional,
        missingRequiredCount: scored?.missingRequiredCount,
        missingIngredientIds: scored?.missingIngredientIds ?? [],
        rankingReasons: scored?.rankingReasons ?? []))
    }

    // Plan battery: each dinner asked independently against the same pantry —
    // the only composition production offers.
    var planRows: [PlanRecipeRow] = []
    for plan in job.plans {
      let effective = RecommendationPolicy.effectiveIngredientIDs(from: Set(plan.availableIds))
      for recipeId in plan.recipeIds {
        let exact = try repo.findMakeable(with: effective, profile: profile, limit: 20)
        var near = try repo.findNearMatch(
          with: effective, profile: profile,
          maxMissingRequired: 1,
          limit: RecommendationPolicy.nearMatchLimit(hasExactMatches: !exact.isEmpty))
        if RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: exact.count, nearMatchCount: near.count) {
          near = try repo.findNearMatch(
            with: effective, profile: profile, maxMissingRequired: 2, limit: 20)
        }
        let all = exact + near
        let scored = all.first { $0.recipe.id == recipeId }
        planRows.append(PlanRecipeRow(
          planId: plan.planId,
          recipeId: recipeId,
          found: scored != nil,
          tier: scored.map { $0.matchTier == .exact ? "exact" : "nearMatch" },
          matchedRequired: scored?.matchedRequired,
          totalRequired: scored?.totalRequired,
          missingRequiredCount: scored?.missingRequiredCount,
          rankingReasons: scored?.rankingReasons ?? []))
      }
    }

    let output = ProbeOutput(probe: "FLFitProbe", pairs: pairRows, plans: planRows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(output).write(to: outURL)
    FileHandle.standardError.write(Data("probe-ok pairs=\(pairRows.count) plans=\(planRows.count)\n".utf8))
  }

  // ---------------------------------------------------------------------
  // Seeding: the production migrations create the schema; corpus rows go in
  // through the same columns BundledDataLoader uses.
  // ---------------------------------------------------------------------
  static func seed(db: DatabaseQueue, job: ProbeJob) throws {
    try db.write { db in
      for ing in job.ingredients {
        // [id, calories, protein, carbs, fat]
        try db.execute(
          sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (?, ?, ?, ?, ?, ?)
          """, arguments: [
            ing[0].int64Value ?? 0, "ing-\(Int(ing[0].doubleValue ?? 0))",
            ing[1].doubleValue ?? 0, ing[2].doubleValue ?? 0,
            ing[3].doubleValue ?? 0, ing[4].doubleValue ?? 0,
          ])
      }
      for meta in job.ingredientNames {
        // [id, name, typical_unit, storage_tip] — names are audit-only.
        try db.execute(
          sql: "UPDATE ingredients SET name = ? WHERE id = ?",
          arguments: [meta[1].stringValue ?? "", meta[0].int64Value ?? 0])
      }
      for arr in job.recipes {
        // [id, title, time_minutes, servings, required[[id,grams]],
        //  optional[[id,grams]], instructions, tags]
        guard let id = arr[0].int64Value,
          let title = arr[1].stringValue,
          let time = arr[2].int64Value,
          let servings = arr[3].int64Value,
          let required = arr[4].arrayValue,
          let optional = arr[5].arrayValue,
          let instructions = arr[6].stringValue
        else { fail("malformed recipe row in job") }
        try db.execute(
          sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (?, ?, ?, ?, ?, ?, 'bundled')
          """, arguments: [
            id, title, time, servings, instructions,
            arr.count > 7 ? (arr[7].int64Value ?? 0) : 0,
          ])
        for line in required {
          guard let lineArr = line.arrayValue,
            let ingId = lineArr[0].int64Value,
            let grams = lineArr[1].doubleValue
          else {
            fail("malformed required line in job")
          }
          try db.execute(
            sql: """
            INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
            VALUES (?, ?, 1, ?, ?)
            """, arguments: [id, ingId, grams, "\(Int(grams)) g"])
        }
        for line in optional {
          guard let lineArr = line.arrayValue,
            let ingId = lineArr[0].int64Value,
            let grams = lineArr[1].doubleValue
          else {
            fail("malformed optional line in job")
          }
          try db.execute(
            sql: """
            INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
            VALUES (?, ?, 0, ?, ?)
            """, arguments: [id, ingId, grams, "\(Int(grams)) g"])
        }
      }
    }
  }
}
