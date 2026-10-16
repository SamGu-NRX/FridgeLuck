import Foundation
import FLIngredientFacts

public enum SubstitutionError: Error, Equatable {
    case unknownRestriction(String)
    case unknownIngredient(String)
    case unknownRole(String)
    case defaultTableNotFound
    case invalidData(String)
}

/// The verdict a restriction check reaches for one ingredient:
///
/// - `allowed`: reviewed facts settle the ingredient against every axis of
///   the eater's restriction — it may be offered.
/// - `violated(reason)`: reviewed facts settle a conflict; the reason names
///   the offending component.
/// - `askUser(reasons)`: composition is unknown (missing facts, an unresolved
///   name, or a composition-unknown product like generic tamari). It fails
///   CLOSED — never offered, surfaced as a question for the user. A "read
///   the bottle" note cannot substitute for the label evidence itself
///   (review blocker b).
public enum RecheckOutcome: Equatable, Sendable {
    case allowed
    case violated(reason: String)
    case askUser(reasons: [String])

    /// Only reviewed, non-conflicting composition is offerable.
    public var isOfferable: Bool {
        switch self {
        case .allowed: return true
        case .violated, .askUser: return false
        }
    }

    public var needsConfirmation: Bool {
        if case .askUser = self { return true }
        return false
    }
}

/// Which FLRestriction axes semantically forbid an ingredient carrying a
/// class. The label registry's forbids lists stay honest against this: a
/// restriction that forbids a class must map to at least one axis that
/// actually excludes it, so class lists and the shared vocabulary cannot
/// drift apart silently (load-time validation in SubstitutionTable).
///
/// Diet facts: the flesh/meat classes are the flesh-derived ones; dairy, egg
/// and honey carry the animal_product MARKER but are eaten by vegetarians,
/// which is why the marker itself is not a diet class — the canonical facts
/// (butter: vegetarian=allowed) and this map agree.
let classCoverage: [AllergenClass: Set<FLRestriction>] = [
    .gluten: [.diet(.glutenFree)],
    .dairy: [.allergen(.milk), .diet(.dairyFree), .diet(.vegan)],
    .egg: [.allergen(.egg), .diet(.vegan)],
    .soy: [.allergen(.soy)],
    .peanut: [.allergen(.peanuts)],
    .treeNut: [.allergen(.treeNuts)],
    .sesame: [.allergen(.sesame)],
    .fish: [.allergen(.fish)],
    .shellfish: [.allergen(.crustaceanShellfish)],
    .meatPoultry: [.diet(.vegetarian), .diet(.vegan), .diet(.pescatarian)],
    .meatGround: [.diet(.vegetarian), .diet(.vegan), .diet(.pescatarian)],
    .meatWholeCutPork: [.diet(.vegetarian), .diet(.vegan), .diet(.pescatarian)],
    .meatWholeCutRed: [.diet(.vegetarian), .diet(.vegan), .diet(.pescatarian)],
    .fleshFish: [.diet(.vegetarian), .diet(.vegan)],
    .fleshShellfish: [.diet(.vegetarian), .diet(.vegan)],
    .honey: [.diet(.vegan)],
    .animalProduct: [.diet(.vegan)],
]

/// The eater side of a lookup: restriction names resolved against the table
/// and folded into one shared-vocabulary restriction set. Two eaters'
/// restrictions union — a household with milk and peanut eaters screens for
/// both (review finding c).
public struct RestrictionSet: Sendable {
    /// The resolved restriction names.
    public let names: [String]
    /// The operative shared-vocabulary restriction the facts store evaluates.
    public let fl: FLRestrictions
    /// The label-registry projection: the union of the restrictions' forbidden
    /// classes. Labels drive evidence diffing (introduced/removed/recheck) —
    /// NOT the refusal decision, which the facts store owns.
    public let forbidden: Set<AllergenClass>

    init(names: [String], table: SubstitutionTable) throws {
        var resolved: [String] = []
        var fl = FLRestrictions(allergens: [], diets: [])
        var forbidden = Set<AllergenClass>()

        for name in names {
            guard let restriction = table.restrictions[name] else {
                throw SubstitutionError.unknownRestriction(name)
            }
            resolved.append(name)
            forbidden.formUnion(restriction.forbids)
            fl.allergens.formUnion(restriction.fl.allergens)
            fl.diets.formUnion(restriction.fl.diets)
        }

        self.names = resolved
        self.fl = fl
        self.forbidden = forbidden
    }
}

/// The outcome of re-checking one substitution pair against an eater's
/// restrictions.
///
/// The class lists remain as EVIDENCE LABELS (what a swap would introduce or
/// remove); the OFFER decision comes from the canonical facts store, which
/// fails closed: a missing record, or one whose composition is not reviewed,
/// yields `askUser`, never a silent pass (review blocker a's fail-open
/// pattern is gone).
public struct AllergenRecheck: Sendable {
    /// Classes the original ingredient carries.
    public let originalClasses: [AllergenClass]
    /// Classes the substitute carries.
    public let substituteClasses: [AllergenClass]
    /// Classes the swap would introduce into the dish.
    public let introduced: [AllergenClass]
    /// Classes the swap would remove from the dish.
    public let removed: [AllergenClass]
    /// Label projection of the substitute's classes against the
    /// restrictions' label forbids. Inspectable context — never the refusal
    /// source (a class label cannot prove composition; the store can).
    public let violated: [AllergenClass]
    /// Store verdict for the ORIGINAL plate ingredient (the both-sides
    /// recheck): a swap can legitimately REMOVE a problem ingredient, so an
    /// original violation does not refuse the swap, but unknown composition
    /// there is surfaced to the user.
    public let originalOutcome: RecheckOutcome
    /// Store verdict for the SUBSTITUTE.
    public let outcome: RecheckOutcome
    /// Set when a conditional failure row names one of the eater's
    /// restrictions for the requested role (review blocker a's seitan case:
    /// the swap is functionally fine but refused for those eaters).
    public let conditionalRefusal: String?

    /// The substitute is not offerable for this eater: a settled violation,
    /// unknown composition, or a conditional refusal. Not the usable-swap
    /// gate on its own — the lookup additionally excludes candidates that
    /// need confirmation (PR #114 review round 2).
    public var isRefused: Bool {
        !outcome.isOfferable || conditionalRefusal != nil
    }

    /// Unknown composition anywhere in the recheck — surface as a question,
    /// not as silence. A candidate with this set is NEVER a usable swap,
    /// including when only the ORIGINAL's composition is unknown (buttermilk
    /// → whole milk under vegetarian). A settled violation on the original
    /// is a different case: it neither refuses nor requires confirmation,
    /// because a known-safe replacement may still remove that violation.
    public var needsConfirmation: Bool {
        outcome.needsConfirmation || originalOutcome.needsConfirmation
    }

    init(
        originalName: String,
        original: IngredientRecord?,
        substitute: IngredientRecord,
        set: RestrictionSet,
        table: SubstitutionTable,
        conditionalRefusal: String?
    ) {
        let originalLabels = Set(original?.classes ?? [])
        let substituteLabels = Set(substitute.classes)
        self.originalClasses = (original?.classes ?? []).sorted { $0.rawValue < $1.rawValue }
        self.substituteClasses = substitute.classes.sorted { $0.rawValue < $1.rawValue }
        self.introduced = substituteLabels.subtracting(originalLabels).sorted { $0.rawValue < $1.rawValue }
        self.removed = originalLabels.subtracting(substituteLabels).sorted { $0.rawValue < $1.rawValue }
        self.violated = substituteLabels.intersection(set.forbidden).sorted { $0.rawValue < $1.rawValue }
        self.conditionalRefusal = conditionalRefusal

        // Both-sides recheck through the canonical store. Absent store ->
        // fail closed (ask the user) rather than pass. With NO restrictions
        // there is nothing to screen — composition unknown cannot harm an
        // unrestricted eater, so the store is not consulted and no safety
        // question is invented. The fail-closed rule protects restricted
        // eaters.
        func factName(_ record: IngredientRecord) -> String {
            record.factsKey ?? record.display
        }
        func verdict(for record: IngredientRecord) -> RecheckOutcome {
            guard let store = table.factsStore else {
                return .askUser(reasons: [
                    "no ingredient-facts store is loaded; composition cannot be checked"
                ])
            }
            switch store.evaluate(ingredient: factName(record), restrictions: set.fl) {
            case .allowed:
                return .allowed
            case .violated(let violation):
                return .violated(reason: violation.reason)
            case .unknown(let unknown):
                return .askUser(reasons: [unknown.reason] + unknown.missing)
            }
        }
        if set.names.isEmpty {
            self.originalOutcome = .allowed
            self.outcome = .allowed
        } else {
            self.originalOutcome = verdict(for: original ?? IngredientRecord(
                display: originalName, fdcID: nil, usdaName: nil,
                macrosPer100g: nil, classes: [], allergenNote: nil, aliases: [], factsKey: nil
            ))
            self.outcome = verdict(for: substitute)
        }
    }
}

/// Deterministic class-label ordering for evidence labels and tests.
func sortedClasses(_ classes: [AllergenClass]) -> [AllergenClass] {
    classes.sorted { $0.rawValue < $1.rawValue }
}
