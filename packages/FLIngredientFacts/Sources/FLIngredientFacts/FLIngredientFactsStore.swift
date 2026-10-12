// The ingredient-facts store: name resolution and fail-closed evaluation.
//
// Evaluation semantics (pinned in packages/FLIngredientFacts/README.md):
//  * violated > unknown > allowed;
//  * unresolvable or unfactored ingredients are unknown, never allowed;
//  * compounds propagate component outcomes;
//  * a variable or unsourced property is unknown, never false;
//  * wheat (an FDA allergen) and gluten (a separate property) are independent
//    axes — evidence for one never settles the other.

import Foundation

public final class FLIngredientFactsStore: @unchecked Sendable {
    private let dataset: FLDataset

    /// - Parameter dataDirectory: the data/ingredient-facts directory holding
    ///   identities.json and facts.json.
    public init(dataDirectory: URL) throws {
        dataset = try FLDataset.load(dataDirectory: dataDirectory)
    }

    // MARK: resolution

    /// Resolves an ingredient name (key, display name, synonym, or preparation
    /// form name) to its canonical identity. Returns nil for unknown names.
    public func resolve(_ name: String) -> FLIngredientIdentity? {
        guard let key = dataset.nameIndex[FLDataset.normalized(name)] else { return nil }
        guard let record = dataset.identities.first(where: { $0.key == key }) else {
            return nil
        }
        return FLIngredientIdentity(
            key: record.key,
            displayName: record.display,
            synonyms: record.synonyms ?? [],
            usdaFdcId: record.usdaFdcId,
            usdaRef: record.usdaRef,
            usdaNote: record.usdaNote,
            appLocalIds: record.appLocalIds ?? []
        )
    }

    /// The canonical fact key for a name, plus any preparation-form override.
    private func resolveFactKey(_ name: String) -> (key: String, form: String?)? {
        let folded = FLDataset.normalized(name)
        guard let key = dataset.nameIndex[folded] else { return nil }
        // Match names are collision-checked at load time, so a form hit is
        // unambiguous.
        if let form = dataset.formIndex[folded] {
            return (form.identity, form.form)
        }
        return (key, nil)
    }

    // MARK: evaluation

    /// Evaluates an ingredient name against restrictions.
    ///
    /// Unresolvable names are unknown (fail closed), never allowed.
    public func evaluate(
        ingredient: String,
        restrictions: FLRestrictions
    ) -> FLEvaluation {
        guard let resolved = resolveFactKey(ingredient) else {
            return .unknown(FLUnknown(
                ingredient: ingredient,
                restriction: restrictions.orderedRestrictions.first ?? .allergen(.milk),
                missing: ["ingredient '\(ingredient)' is not in the dataset"],
                reason: "unresolved ingredient: evaluation fails closed"
            ))
        }
        guard let entry = dataset.facts[resolved.key] else {
            return .unknown(FLUnknown(
                ingredient: ingredient,
                restriction: restrictions.orderedRestrictions.first ?? .allergen(.milk),
                missing: ["no facts exist for '\(resolved.key)'"],
                reason: "unfactored ingredient: evaluation fails closed"
            ))
        }
        let canonical = dataset.identities.first(where: { $0.key == resolved.key })?.display
        let context = EvaluationContext(store: self, restrictions: restrictions)
        return context.evaluate(
            entry: entry,
            form: resolved.form,
            ingredientLabel: canonical ?? ingredient,
            depth: 0
        )
    }

    // MARK: evaluation internals

    /// Per-evaluation walker. One instance carries the restriction set;
    /// component recursion reuses it.
    private struct EvaluationContext {
        let store: FLIngredientFactsStore
        let restrictions: FLRestrictions

        /// A preparation form's override wins over the identity's own fact;
        /// absent either, the fact is simply missing.
        func fact(
            for restriction: FLRestriction,
            entry: FactEntry,
            form: String?
        ) -> FactObject? {
            let override = form.flatMap { entry.forms?[$0] }
            switch restriction {
            case .allergen(let allergen):
                if let override, let fact = override.allergens?[allergen.rawValue] {
                    return fact
                }
                return entry.allergens?[allergen.rawValue]
            case .diet(let diet):
                if let override, let fact = override.diets?[diet.rawValue] {
                    return fact
                }
                return entry.diets?[diet.rawValue]
            }
        }

        func evaluate(
            entry: FactEntry,
            form: String?,
            ingredientLabel: String,
            depth: Int
        ) -> FLEvaluation {
            var violations: [FLViolation] = []
            var unknownMissing: [String] = []
            var unknownRestriction: FLRestriction?
            var unknownAllergens = Set<FLAllergen>()
            var unknownDiets = Set<FLDiet>()
            var allowedEvidence: [FLEvidence] = []

            func recordUnknown(_ restriction: FLRestriction, note: String?) {
                if unknownRestriction == nil { unknownRestriction = restriction }
                switch restriction {
                case .allergen(let allergen): unknownAllergens.insert(allergen)
                case .diet(let diet): unknownDiets.insert(diet)
                }
                let what: String
                switch restriction {
                case .allergen(let allergen):
                    what = "allergen '\(allergen.rawValue)' fact for '\(entry.key)' is missing or unknown"
                case .diet(let diet):
                    what = "diet '\(diet.rawValue)' fact for '\(entry.key)' is missing or unknown"
                }
                var text = what
                if let note, !note.isEmpty { text += " — \(note)" }
                unknownMissing.append(text)
            }

            for restriction in restrictions.orderedRestrictions {
                let fact = self.fact(for: restriction, entry: entry, form: form)
                switch fact?.state {
                case "contains", "violated":
                    if let fact, let evidence = fact.evidence {
                        let reason: String
                        switch restriction {
                        case .allergen(let allergen):
                            reason = "'\(ingredientLabel)' contains the allergen '\(allergen.rawValue)'"
                        case .diet(let diet):
                            reason = "'\(ingredientLabel)' is not compatible with the \(diet.rawValue) diet"
                        }
                        violations.append(FLViolation(
                            ingredient: ingredientLabel,
                            restriction: restriction,
                            reason: reason,
                            evidence: [evidence]
                        ))
                    }
                case "free", "allowed":
                    if let fact, let evidence = fact.evidence {
                        allowedEvidence.append(evidence)
                    }
                case "unknown":
                    recordUnknown(restriction, note: fact?.evidence?.note)
                default:
                    recordUnknown(restriction, note: nil)
                }
            }

            if let violation = violations.first {
                return .violated(violation)
            }

            // Nothing settled at the entry level: fall back to components for
            // compounds. Certain and typical components can settle or violate;
            // a component whose presence itself varies cannot settle anything.
            if !unknownMissing.isEmpty, depth < 8,
               let components = entry.components, !components.isEmpty {
                var componentUnknowns: [String] = []
                for component in components {
                    let label = "'\(component.key)' in '\(entry.key)'"
                    switch component.certainty {
                    case "certain", "typical":
                        guard let componentEntry = store.dataset.facts[component.key] else {
                            componentUnknowns.append("composition of \(label) is unrecorded")
                            continue
                        }
                        switch evaluate(
                            entry: componentEntry, form: nil,
                            ingredientLabel: component.key, depth: depth + 1
                        ) {
                        case .violated(let violation):
                            var evidence = violation.evidence
                            if let componentEvidence = component.evidence {
                                evidence.append(componentEvidence)
                            }
                            return .violated(FLViolation(
                                ingredient: ingredientLabel,
                                restriction: violation.restriction,
                                reason: "component \(violation.reason)",
                                evidence: evidence
                            ))
                        case .unknown(let unknown):
                            componentUnknowns.append(
                                "component \(component.key): \(unknown.missing.joined(separator: "; "))")
                        case .allowed(let evidence):
                            allowedEvidence.append(contentsOf: evidence)
                        }
                    case "variable":
                        // Presence varies: the component may still be evaluated
                        // on its own facts, but a violation only means SOME
                        // products carry it, which is unknown, not violated.
                        guard let componentEntry = store.dataset.facts[component.key] else {
                            componentUnknowns.append("composition of \(label) is unrecorded")
                            continue
                        }
                        switch evaluate(
                            entry: componentEntry, form: nil,
                            ingredientLabel: component.key, depth: depth + 1
                        ) {
                        case .violated(let violation):
                            componentUnknowns.append(
                                "whether \(label) is present varies by product; when present it "
                                + violation.reason)
                        case .unknown(let unknown):
                            componentUnknowns.append(
                                "component \(component.key) (presence varies): "
                                + unknown.missing.joined(separator: "; "))
                        case .allowed(let evidence):
                            allowedEvidence.append(contentsOf: evidence)
                        }
                    default:
                        componentUnknowns.append(
                            "composition of \(label) is unverified (certainty unknown)")
                    }
                }
                if !componentUnknowns.isEmpty {
                    return .unknown(FLUnknown(
                        ingredient: ingredientLabel,
                        restriction: unknownRestriction
                            ?? restrictions.orderedRestrictions.first ?? .allergen(.milk),
                        missing: unknownMissing + componentUnknowns,
                        reason: "compound composition leaves restrictions undecided"
                    ))
                }
                // Every component settled allowed. Diet compatibility is
                // component-class-based, so diet unknowns are settled;
                // allergen absence additionally requires the composition to be
                // known complete (an unlisted component could carry one).
                if unknownAllergens.isEmpty || entry.compositionComplete == true {
                    return .allowed(allowedEvidence)
                }
                return .unknown(FLUnknown(
                    ingredient: ingredientLabel,
                    restriction: unknownRestriction
                        ?? restrictions.orderedRestrictions.first ?? .allergen(.milk),
                    missing: unknownMissing + ["composition of '\(entry.key)' is incomplete"],
                    reason: "composition is not known to be complete"
                ))
            }

            if unknownMissing.isEmpty {
                return .allowed(allowedEvidence)
            }
            return .unknown(FLUnknown(
                ingredient: ingredientLabel,
                restriction: unknownRestriction
                    ?? restrictions.orderedRestrictions.first ?? .allergen(.milk),
                missing: unknownMissing,
                reason: "facts do not settle the restricted properties"
            ))
        }
    }
}
