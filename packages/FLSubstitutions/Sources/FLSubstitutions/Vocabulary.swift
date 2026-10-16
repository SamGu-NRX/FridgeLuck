import Foundation

/// The 11 functional roles a substitution pair can serve (SPEC overhaul-20261011 §3.5).
public enum Role: String, CaseIterable, Codable, Sendable {
    case acid
    case aromatic
    case binder
    case fat
    case garnish
    case leavening
    case liquid
    case protein
    case sweetener
    case thickener
    case umami
}

/// Allergen, flesh, and marker classes attached to ingredients.
///
/// The first nine cases are the shared Suite C contract classes
/// (`evaluation/suites/recipes/allergens.json`, S-CONTRACT in the table's
/// source registry). The flesh/meat classes back the vegetarian, vegan, and
/// pescatarian diet restrictions; `animalProduct` and `honey` are markers the
/// contract's diet claims forbid transitively. Wheat-bearing ingredients are
/// classed `gluten` — the contract has no separate `wheat` class.
public enum AllergenClass: String, CaseIterable, Codable, Sendable {
    // Shared contract classes.
    case gluten
    case dairy
    case egg
    case soy
    case peanut
    case treeNut = "tree_nut"
    case sesame
    case fish
    case shellfish
    // Flesh / meat classes (documented extension; diet restrictions).
    case meatPoultry = "meat_poultry"
    case meatGround = "meat_ground"
    case meatWholeCutPork = "meat_whole_cut_pork"
    case meatWholeCutRed = "meat_whole_cut_red"
    case fleshFish = "flesh_fish"
    case fleshShellfish = "flesh_shellfish"
    // Markers (documented extension).
    case animalProduct = "animal_product"
    case honey
}

/// Evidence strength for a claim. `conflict` and `unsupported` are recorded
/// states, never silently resolved (SPEC §3.5; PR #49 semantics).
public enum EvidenceStatus: String, Codable, Sendable {
    /// Primary or peer-reviewed guidance states the amount or function.
    case sourced
    /// Standard practice, but no retrieved source states this exact amount.
    case convention
    /// Two evidence statements disagree; both are recorded.
    case conflict
    /// Retrieved evidence says the claim does not hold.
    case unsupported
    /// No usable evidence either way.
    case unknown
}
