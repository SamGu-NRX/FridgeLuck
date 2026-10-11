import Foundation
import FLTaste

/// Synthetic ingredient prices. The app catalog carries no price data, so
/// budget constraints need a deterministic proxy: a three-tier macro
/// heuristic per 100 g. Documented in SIM-ASSUMPTIONS.md as an assumption,
/// not calibrated data; Part 3 may sweep it.
///
/// Tiers: protein-rich (>= 10 g protein/100 g — meat, fish, cheese) is
/// premium; pure fats (>= 30 g fat/100 g — oils, butter, nuts) are mid;
/// everything else (produce, grains, staples) is cheap. The tiers are chosen
/// so a protein main costs roughly 3x a staple side, which is what makes a
/// weekly budget bite.
public struct PriceModel: Sendable {

    public let proteinRichPerGram: Double
    public let fatPerGram: Double
    public let staplePerGram: Double

    public init(
        proteinRichPerGram: Double = 0.011, fatPerGram: Double = 0.009,
        staplePerGram: Double = 0.0035
    ) {
        self.proteinRichPerGram = proteinRichPerGram
        self.fatPerGram = fatPerGram
        self.staplePerGram = staplePerGram
    }

    public func pricePerGram(_ ingredient: CatalogIngredient) -> Double {
        if ingredient.proteinPer100g >= 10 { return proteinRichPerGram }
        if ingredient.fatPer100g >= 30 { return fatPerGram }
        return staplePerGram
    }

    /// What the required ingredients cost. Optional uses are excluded: a
    /// shopper plans for the dish, not its garnishes, and only buys what it
    /// needs.
    public func recipeCost(_ recipe: CatalogRecipe, catalog: RecipeCatalog) -> Double {
        var total = 0.0
        for use in recipe.requiredIngredients {
            guard let ingredient = catalog.ingredients[use.id] else { continue }
            total += pricePerGram(ingredient) * use.grams
        }
        return total
    }
}

/// One purchase: grams of an ingredient bought in a week. Lots spoil, so
/// long-forgotten stock leaves the pantry.
public struct PantryLot: Sendable, Equatable {
    public let ingredient: IngredientID
    public let grams: Double
    /// Week index the lot was bought in; weeks are 0-based run weeks.
    public let boughtInWeek: Int
}

/// The household pantry: lots of ingredient grams that deplete as recipes
/// cook and spoil after a shelf life. Availability is real: a recipe is
/// cookable only when the pantry still holds every required ingredient in
/// full.
public struct Pantry: Sendable {

    public private(set) var lots: [PantryLot]

    public init(lots: [PantryLot] = []) {
        self.lots = lots
    }

    /// Current stock by ingredient. Callers sort before iterating; this map
    /// itself never drives ordering.
    public func gramsByIngredient() -> [IngredientID: Double] {
        var grams: [IngredientID: Double] = [:]
        for lot in lots { grams[lot.ingredient, default: 0] += lot.grams }
        return grams
    }

    public func grams(of ingredient: IngredientID) -> Double {
        var total = 0.0
        for lot in lots where lot.ingredient == ingredient { total += lot.grams }
        return total
    }

    /// True when every required use is in stock in full (1e-9 tolerance for
    /// float subtraction). Optional uses do not block: the recipe lists them
    /// as omittable.
    public func supports(_ recipe: CatalogRecipe) -> Bool {
        let stock = gramsByIngredient()
        for use in recipe.requiredIngredients {
            if (stock[use.id] ?? 0) + 1e-9 < use.grams { return false }
        }
        return true
    }

    public mutating func add(grams: Double, of ingredient: IngredientID, week: Int) {
        lots.append(PantryLot(ingredient: ingredient, grams: grams, boughtInWeek: week))
    }

    /// Consumes the required grams of a cooked recipe, oldest lots first.
    /// Optional uses are consumed too when in stock (they get used if
    /// present). Call only when `supports(recipe)` holds.
    public mutating func consume(_ recipe: CatalogRecipe) {
        for use in recipe.requiredIngredients {
            subtract(use.grams, of: use.id)
        }
        for use in recipe.optionalIngredients {
            let present = grams(of: use.id)
            if present > 0 { subtract(min(use.grams, present), of: use.id) }
        }
    }

    /// FIFO partial consumption of one ingredient.
    private mutating func subtract(_ amount: Double, of ingredient: IngredientID) {
        var remaining = amount
        var next: [PantryLot] = []
        for lot in lots {
            if remaining > 1e-9, lot.ingredient == ingredient {
                let used = min(lot.grams, remaining)
                remaining -= used
                if lot.grams - used > 1e-9 {
                    next.append(
                        PantryLot(
                            ingredient: lot.ingredient, grams: lot.grams - used,
                            boughtInWeek: lot.boughtInWeek))
                }
            } else {
                next.append(lot)
            }
        }
        lots = next
    }

    /// Drops lots bought long enough ago to have spoiled. A lot bought in
    /// week w survives through week w + shelfLifeWeeks - 1 and is dropped at
    /// the start of week w + shelfLifeWeeks. Called at the start of each
    /// week, before shopping.
    public mutating func spoil(currentWeek: Int, shelfLifeWeeks: Int) {
        lots = lots.filter { currentWeek - $0.boughtInWeek < shelfLifeWeeks }
    }
}

/// The hard filter that decides which recipes can appear at all: the
/// household's restriction union, the neverSuggest list, and any lost
/// capability. This is the gate a learned ranker can never override
/// (SPEC 3.3: hard filters survive any learning reset).
public struct FeasibilityFilter: Sendable {

    public var unionRestrictions: [Restriction]
    public var neverSuggest: Set<IngredientID>
    /// Instruction substrings that became infeasible (lost capability), e.g.
    /// "bake" after the oven broke.
    public var capabilityNeedles: [String]

    public init(
        unionRestrictions: [Restriction] = [], neverSuggest: Set<IngredientID> = [],
        capabilityNeedles: [String] = []
    ) {
        self.unionRestrictions = unionRestrictions
        self.neverSuggest = neverSuggest
        self.capabilityNeedles = capabilityNeedles
    }

    /// True when the recipe clears every hard filter, ignoring the pantry.
    /// Allergies block required and optional uses alike (an allergy does not
    /// distinguish); diets require the matching tag; neverSuggest blocks any
    /// listed ingredient.
    public func isLegal(_ recipe: CatalogRecipe) -> Bool {
        let used = recipe.requiredIngredients.map(\.id) + recipe.optionalIngredients.map(\.id)
        for restriction in unionRestrictions {
            switch restriction.kind {
            case .allergy:
                if let ingredient = IngredientID(restriction.target), used.contains(ingredient) {
                    return false
                }
            case .diet:
                if restriction.target == "vegetarian", !recipe.hasTag(.vegetarian) { return false }
                if restriction.target == "vegan", !recipe.hasTag(.vegan) { return false }
            }
        }
        for ingredient in neverSuggest where used.contains(ingredient) {
            return false
        }
        let lower = recipe.instructions.lowercased()
        for needle in capabilityNeedles where lower.contains(needle) {
            return false
        }
        return true
    }

    /// The feasible set at a moment: restriction-legal recipes the pantry
    /// supports, sorted by id so every downstream consumer sees one order.
    public func feasibleRecipes(catalog: RecipeCatalog, pantry: Pantry) -> [CatalogRecipe] {
        var feasible: [CatalogRecipe] = []
        for id in catalog.recipes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let recipe = catalog.recipes[id] else { continue }
            if isLegal(recipe) && pantry.supports(recipe) {
                feasible.append(recipe)
            }
        }
        return feasible
    }
}
