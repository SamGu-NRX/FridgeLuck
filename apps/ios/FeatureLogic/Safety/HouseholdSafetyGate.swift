import Foundation

/// One allergen group the household can restrict, named by the onboarding
/// group id (`AllergenSupport.groups`). Pure framework type: the Feature layer
/// derives which groups a household's stored ingredient ids mean; this type
/// carries what the group screens against.
public enum HouseholdAllergenGroup: String, CaseIterable, Sendable, Codable, Hashable {
  case milk
  case egg
  case peanut
  case treeNut = "tree_nut"
  case soy
  case wheatGluten = "wheat_gluten"
  case fish
  case shellfish
  case sesame
  case mustard

  /// The bundle composition class this group screens against. A recipe line
  /// classed with this class is never offered to a household restricting the
  /// group — no matter how the line resolved, or whether it resolved at all.
  public var ingredientClass: String {
    switch self {
    case .milk: return "dairy"
    case .egg: return "egg"
    case .peanut: return "peanut"
    case .treeNut: return "tree_nut"
    case .soy: return "soy"
    case .wheatGluten: return "gluten"
    case .fish: return "fish"
    case .shellfish: return "shellfish"
    case .sesame: return "sesame"
    case .mustard: return "mustard"
    }
  }
}

/// The household's selected diet, named by the profile diet id.
public enum HouseholdDiet: String, CaseIterable, Sendable, Codable, Hashable {
  case vegetarian
  case pescatarian
  case vegan
  case keto

  /// Classes that certainly break the diet. Mirrors the data pipeline's claim
  /// blockers (`data/recipes/tools/compile_bundle.py`): vegetarian blocks
  /// {meat, fish, shellfish}, vegan adds {animal, dairy, egg, honey}.
  /// Pescatarian has no pipeline claim; it blocks land-animal classes
  /// (meat and generic animal derivatives) and allows fish and shellfish.
  var blockedClasses: Set<String> {
    switch self {
    case .vegetarian: return ["meat", "fish", "shellfish"]
    case .pescatarian: return ["meat", "animal"]
    case .vegan: return ["meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"]
    case .keto: return []
    }
  }
}

/// The household side of the screen: which allergen groups are restricted and
/// which single diet is selected. Derived by the caller from the stored health
/// profile at query time, so ingredient rows added after onboarding are covered.
public struct HouseholdSafetyProfile: Equatable, Sendable {
  public var allergenGroups: Set<HouseholdAllergenGroup>
  public var diet: HouseholdDiet?

  public init(allergenGroups: Set<HouseholdAllergenGroup> = [], diet: HouseholdDiet? = nil) {
    self.allergenGroups = allergenGroups
    self.diet = diet
  }

  /// A household with any allergy or any diet is screened strictly: a line
  /// whose composition is unknown never passes.
  public var hasAnyRestriction: Bool { !allergenGroups.isEmpty || diet != nil }
}

/// One recipe line's composition classes, taken from the shipped bundle's
/// per-ingredient `classes` array. An empty set means the line's composition
/// could not be settled (no vocabulary row, or a legacy line outside the
/// bundle vocabulary) and screens as unknown.
public struct RecipeLineSafety: Equatable, Sendable {
  public var classes: Set<String>

  public init(classes: Set<String>) {
    self.classes = classes
  }

  /// The fail-closed stand-in for a line whose classes are unknown.
  public static let unknown = RecipeLineSafety(classes: ["unknown"])
}

/// Why the screen refused a recipe or a substitute.
public enum HouseholdSafetyBlock: Equatable, Sendable {
  /// A line carries the class of a restricted allergen group.
  case allergen(HouseholdAllergenGroup)
  /// The diet cannot be proven from the line classes (keto always: no class
  /// expresses keto).
  case diet(HouseholdDiet)
  /// A line's composition is unknown and the household restricts something.
  case unknownComposition
}

public enum HouseholdSafetyVerdict: Equatable, Sendable {
  case allowed
  case blocked(HouseholdSafetyBlock)

  public var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }
}

/// The one screen every recipe-offering and swap-offering surface runs before
/// anything reaches the household: catalog recommendations (exact and
/// near-match), substitution offers, the cook-time swap recheck, weekly-plan
/// candidates and swaps, and LeChef swap proposals (through the recheck).
///
/// Fail-closed contract, pinned by the shipped bundle's per-ingredient
/// `classes` (PR burst9-fridgeluck-catalog-data): every bundle vocabulary
/// entry carries classes; the `unknown` class blocks every allergen and diet
/// check for a household that restricts anything. A line with no classes at
/// all screens as unknown for the same reason.
///
/// Keto fails closed by design: no composition class expresses low-carb, so a
/// keto household is offered no catalog recipe. `ketoMaxCarbsPerServingGrams`
/// names the constant Sam can set to admit recipes under a per-serving carbs
/// limit; while it stays `nil` the screen blocks every keto query.
public enum HouseholdSafetyGate {
  /// Per-serving carbs (g) a keto household would accept, once Sam picks the
  /// limit (candidates evaluated: 15, 20, 30 g). `nil` keeps keto fail-closed:
  /// no catalog recipe passes, because no composition class proves low-carb.
  public static let ketoMaxCarbsPerServingGrams: Double? = nil

  /// Group → class mapping, exposed so tests can mutate it and prove the
  /// sweep catches a dropped entry.
  public static let groupToClass: [HouseholdAllergenGroup: String] = {
    var mapping: [HouseholdAllergenGroup: String] = [:]
    for group in HouseholdAllergenGroup.allCases {
      mapping[group] = group.ingredientClass
    }
    return mapping
  }()

  /// Screens a recipe (or a single substitute line) for one household.
  ///
  /// - Parameters:
  ///   - household: the household's allergen groups and diet.
  ///   - lines: one entry per recipe line; an empty set screens as unknown.
  ///   - perServingCarbsGrams: the recipe's per-serving carbs, when known.
  ///     Only read for keto while `ketoMaxCarbsPerServingGrams` is set.
  public static func screen(
    household: HouseholdSafetyProfile,
    lines: [RecipeLineSafety],
    perServingCarbsGrams: Double? = nil
  ) -> HouseholdSafetyVerdict {
    // Allergen groups first: the class of a restricted group on any line
    // refuses the recipe outright.
    for group in HouseholdAllergenGroup.allCases where household.allergenGroups.contains(group) {
      let forbiddenClass = groupToClass[group] ?? group.ingredientClass
      for line in lines where line.classes.contains(forbiddenClass) {
        return .blocked(.allergen(group))
      }
    }

    if let diet = household.diet {
      if diet == .keto {
        // No class expresses keto: fail closed unless a carbs limit has been
        // set, and even then only when the recipe's carbs are actually known.
        if let limit = ketoMaxCarbsPerServingGrams, let carbs = perServingCarbsGrams,
          carbs <= limit
        {
          return .allowed
        }
        return .blocked(.diet(.keto))
      }
      for line in lines {
        let violation = diet.blockedClasses.intersection(line.classes)
        if !violation.isEmpty {
          return .blocked(.diet(diet))
        }
      }
    }

    // Unknown composition blocks any household that restricts something:
    // the coarse marker cannot say which restriction it would break.
    if household.hasAnyRestriction {
      for line in lines where line.classes.isEmpty || line.classes.contains("unknown") {
        return .blocked(.unknownComposition)
      }
    }

    return .allowed
  }

  /// Convenience for a single-line screen (one substitute ingredient).
  public static func screen(
    household: HouseholdSafetyProfile, line: RecipeLineSafety,
    perServingCarbsGrams: Double? = nil
  ) -> HouseholdSafetyVerdict {
    screen(
      household: household, lines: [line], perServingCarbsGrams: perServingCarbsGrams)
  }
}
