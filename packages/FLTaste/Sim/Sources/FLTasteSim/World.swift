import Foundation
import FLTaste

/// What one week's shop did. Part of the ground truth: a scorer can see
/// exactly which scarcity a household faced.
public struct ShoppingRecord: Sendable, Equatable {
    public let week: Int
    public let plannedRecipeIds: [String]
    public let boughtRecipeIds: [String]
    public let budgetForTheWeek: Double
    public let spent: Double
    /// Grams bought per ingredient, sorted by id when serialized.
    public let boughtGrams: [IngredientID: Double]
}

/// The world the household lives in: the pantry, the weekly budget, and any
/// lost capabilities. Owns physical reality; owns no taste. The simulator
/// decides what to plan (it owns the household's taste); the world decides
/// what the budget and pantry actually allow.
public struct World: Sendable {

    public let catalog: RecipeCatalog
    public let priceModel: PriceModel
    /// Baseline weekly budget from config; `currentBudget` = baseline times
    /// the applied budget factor (1.0 until a shift changes it).
    public let baseWeeklyBudget: Double
    public private(set) var budgetFactor: Double
    public private(set) var currentBudget: Double
    public private(set) var pantry: Pantry
    public private(set) var capabilityNeedles: [String]
    public private(set) var lastShopping: ShoppingRecord?

    public init(config: SimConfig, catalog: RecipeCatalog, priceModel: PriceModel = PriceModel()) {
        self.catalog = catalog
        self.priceModel = priceModel
        self.baseWeeklyBudget = config.weeklyBudget
        self.budgetFactor = 1.0
        self.currentBudget = config.weeklyBudget
        self.pantry = Pantry()
        self.capabilityNeedles = []
    }

    /// Spoils old lots and re-arms the weekly budget. Call once per week,
    /// before shopping.
    public mutating func startWeek(week: Int, shelfLifeWeeks: Int) {
        pantry.spoil(currentWeek: week, shelfLifeWeeks: shelfLifeWeeks)
        currentBudget = baseWeeklyBudget * budgetFactor
    }

    /// Applies a budget-change shift from now on: every later week budgets
    /// `baseline * factor`. Income changes persist.
    public mutating func applyBudgetFactor(_ factor: Double) {
        budgetFactor = factor
        currentBudget = baseWeeklyBudget * factor
    }

    public mutating func loseCapability(needle: String) {
        guard !capabilityNeedles.contains(needle) else { return }
        capabilityNeedles.append(needle)
    }

    /// Buys the required ingredients of each planned recipe, in plan order,
    /// while the week's budget lasts. A plan costing more than the remaining
    /// budget is skipped (the household picks a different meal, or eats
    /// down the pantry). Shared ingredients accumulate.
    @discardableResult
    public mutating func shop(week: Int, plans: [CatalogRecipe]) -> ShoppingRecord {
        var remaining = currentBudget
        var spent = 0.0
        var bought: [IngredientID: Double] = [:]
        var boughtIds: [String] = []
        for plan in plans {
            let cost = priceModel.recipeCost(plan, catalog: catalog)
            guard cost <= remaining + 1e-9 else { continue }
            for use in plan.requiredIngredients {
                pantry.add(grams: use.grams, of: use.id, week: week)
                bought[use.id, default: 0] += use.grams
            }
            spent += cost
            remaining -= cost
            boughtIds.append(plan.id.rawValue)
        }
        let record = ShoppingRecord(
            week: week,
            plannedRecipeIds: plans.map { $0.id.rawValue },
            boughtRecipeIds: boughtIds,
            budgetForTheWeek: currentBudget,
            spent: spent,
            boughtGrams: bought)
        lastShopping = record
        return record
    }

    /// The filter that reflects current restrictions, neverSuggest and
    /// capabilities.
    public func feasibilityFilter(restrictions: [Restriction], neverSuggest: Set<IngredientID>)
        -> FeasibilityFilter
    {
        FeasibilityFilter(
            unionRestrictions: restrictions,
            neverSuggest: neverSuggest,
            capabilityNeedles: capabilityNeedles)
    }

    public mutating func consume(_ recipe: CatalogRecipe) {
        pantry.consume(recipe)
    }
}
