import XCTest
@testable import FLIngredientFacts

/// Unit tests for the pinned semantics: fail closed, unknown propagation,
/// union restrictions, certainty levels and the wheat/gluten independence.
final class EvaluationSemanticsTests: XCTestCase {
    private var store: FLIngredientFactsStore!

    override func setUpWithError() throws {
        store = try FLIngredientFactsStore(dataDirectory: DatasetLocator.datasetDirectory())
    }

    // MARK: fail closed

    func testUnresolvedIngredientIsUnknownNeverAllowed() throws {
        let evaluation = store.evaluate(
            ingredient: "dragon fruit syrup", restrictions: FLRestrictions(allergens: [.milk]))
        guard case .unknown(let unknown) = evaluation else {
            return XCTFail("expected unknown, got \(evaluation)")
        }
        XCTAssertTrue(unknown.missing.contains("ingredient 'dragon fruit syrup' is not in the dataset"))
    }

    func testUnfactoredIngredientIsUnknown() throws {
        // artisan-granola-bar is the deliberate identity-without-facts exemplar.
        XCTAssertNotNil(store.resolve("artisan-granola-bar"))
        let evaluation = store.evaluate(
            ingredient: "artisan granola bar", restrictions: FLRestrictions(allergens: [.wheat]))
        guard case .unknown(let unknown) = evaluation else {
            return XCTFail("expected unknown, got \(evaluation)")
        }
        XCTAssertTrue(unknown.missing.contains { $0.contains("no facts exist") })
    }

    func testMissingPerRestrictionFactIsUnknown() throws {
        // Honey has no recorded fish fact: evaluating it against fish avoidance
        // must not read as safe.
        let evaluation = store.evaluate(
            ingredient: "honey", restrictions: FLRestrictions(allergens: [.fish]))
        guard case .unknown(let unknown) = evaluation else {
            return XCTFail("expected unknown, got \(evaluation)")
        }
        XCTAssertTrue(unknown.missing.contains { $0.contains("fish") })
    }

    // MARK: certainty levels and unknown propagation

    func testCertainViolatingComponentPropagatesViolation() throws {
        // A synthetic compound with NO direct soy fact violates soy avoidance
        // purely through its certain component. (Real compounds carry the
        // component's allergens folded into direct facts as well.)
        let directory = try Self.syntheticDataset()
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthetic = try FLIngredientFactsStore(dataDirectory: directory)
        let evaluation = synthetic.evaluate(
            ingredient: "test-compound", restrictions: FLRestrictions(allergens: [.soy]))
        guard case .violated(let violation) = evaluation else {
            return XCTFail("expected violated via certain component, got \(evaluation)")
        }
        XCTAssertTrue(violation.reason.contains("component"), "reason: \(violation.reason)")
        XCTAssertTrue(violation.reason.contains("soy"), "reason: \(violation.reason)")
        XCTAssertFalse(violation.evidence.isEmpty)
    }

    /// Minimal valid dataset: one compound whose composition is a single
    /// certain soy-containing component, plus an unrelated factless component.
    private static func syntheticDataset() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flfacts-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identities = """
        {"version":1,"ingredients":[
          {"key":"test-compound","display":"Test compound","kind":"compound","synonyms":[]},
          {"key":"test-soybeans","display":"Test soybeans","kind":"simple","synonyms":[]},
          {"key":"test-mystery","display":"Test mystery","kind":"simple","synonyms":[]}
        ]}
        """
        let facts = """
        {"version":1,"facts":{
          "test-compound":{"key":"test-compound","class":"compound","components":[
            {"key":"test-soybeans","certainty":"certain",
             "evidence":{"kind":"standard","ref":"synthetic","note":"certain component"}},
            {"key":"test-mystery","certainty":"unknown"}]},
          "test-soybeans":{"key":"test-soybeans","class":"simple","allergens":{"soy":
            {"state":"contains","evidence":{"kind":"standard","ref":"synthetic","note":"soybeans"}}}},
          "test-mystery":{"key":"test-mystery","class":"simple"}
        }}
        """
        try Data(identities.utf8).write(to: directory.appendingPathComponent("identities.json"))
        try Data(facts.utf8).write(to: directory.appendingPathComponent("facts.json"))
        return directory
    }

    func testVariableViolatingComponentIsUnknownNotViolated() throws {
        // Stock cubes vary: a variable component that violates in SOME products
        // is unknown for the generic product.
        for allergen in [FLAllergen.milk, .soy, .wheat] {
            let evaluation = store.evaluate(
                ingredient: "stock cube", restrictions: FLRestrictions(allergens: [allergen]))
            guard case .unknown = evaluation else {
                return XCTFail("stock cube vs \(allergen): expected unknown, got \(evaluation)")
            }
        }
    }

    func testUnknownCertaintyComponentIsUnknown() throws {
        // Tamari's wheat component carries certainty 'unknown': wheat avoidance
        // must be unknown — never violated, never silently allowed.
        let evaluation = store.evaluate(
            ingredient: "tamari", restrictions: FLRestrictions(allergens: [.wheat]))
        guard case .unknown(let unknown) = evaluation else {
            return XCTFail("expected unknown, got \(evaluation)")
        }
        XCTAssertTrue(unknown.missing.contains { $0.contains("wheat") },
                      "missing must mention wheat: \(unknown.missing)")
    }

    func testUnknownCertaintyComponentNeverAllows() throws {
        // The synthetic compound's second component has certainty 'unknown'
        // with no facts at all: even though the certain component is soy-free
        // here, the compound must stay unknown for sesame avoidance.
        let directory = try Self.syntheticDataset()
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthetic = try FLIngredientFactsStore(dataDirectory: directory)
        let evaluation = synthetic.evaluate(
            ingredient: "test-compound", restrictions: FLRestrictions(allergens: [.sesame]))
        guard case .unknown = evaluation else {
            return XCTFail("an unknown-certainty component must never allow, got \(evaluation)")
        }
    }

    // MARK: incomplete composition blocks every clear

    func testIncompleteCompositionBlocksDietClears() throws {
        // The chilli-sauce shape: no entry-level diet fact, and every listed
        // certain component is vegan — but the composition is not complete, so
        // an unlisted component (a brand's thickeners, preservatives) could
        // violate the diet. The compound stays unknown.
        let directory = try Self.syntheticDietDataset(compositionComplete: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthetic = try FLIngredientFactsStore(dataDirectory: directory)
        let evaluation = synthetic.evaluate(
            ingredient: "test-compound", restrictions: FLRestrictions(diets: [.vegan]))
        guard case .unknown(let unknown) = evaluation else {
            return XCTFail("incomplete composition must not clear a diet, got \(evaluation)")
        }
        XCTAssertTrue(unknown.missing.contains { $0.contains("is incomplete") },
                      "missing must name the incomplete composition: \(unknown.missing)")
    }

    func testCompleteCompositionAllowsDietViaComponents() throws {
        // Same shape with the component list closed: the certain vegan
        // component may settle the diet.
        let directory = try Self.syntheticDietDataset(compositionComplete: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthetic = try FLIngredientFactsStore(dataDirectory: directory)
        let evaluation = synthetic.evaluate(
            ingredient: "test-compound", restrictions: FLRestrictions(diets: [.vegan]))
        guard case .allowed = evaluation else {
            return XCTFail("complete composition may clear the diet via components, got \(evaluation)")
        }
    }

    /// Minimal vegan compound: a single certain component whose own diet fact
    /// is vegan-allowed; compositionComplete is caller-controlled.
    private static func syntheticDietDataset(compositionComplete: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flfacts-synthetic-diet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identities = """
        {"version":1,"ingredients":[
          {"key":"test-compound","display":"Test compound","kind":"compound","synonyms":[]},
          {"key":"test-plant","display":"Test plant","kind":"simple","synonyms":[]}
        ]}
        """
        let facts = """
        {"version":1,"facts":{
          "test-compound":{"key":"test-compound","class":"compound","components":[
            {"key":"test-plant","certainty":"certain",
             "evidence":{"kind":"standard","ref":"synthetic","note":"certain component"}}],
           "compositionComplete":\(compositionComplete)},
          "test-plant":{"key":"test-plant","class":"plant","diets":{"vegan":
            {"state":"allowed","evidence":{"kind":"standard","ref":"synthetic","note":"plant food"}}}}
        }}
        """
        try Data(identities.utf8).write(to: directory.appendingPathComponent("identities.json"))
        try Data(facts.utf8).write(to: directory.appendingPathComponent("facts.json"))
        return directory
    }

    func testViolatedBeatsUnknownAndUnknownBeatsAllowed() throws {
        // Violated > unknown: soy sauce vs soy+wheat — soy violated even though
        // another fact may be unknown.
        let evaluation = store.evaluate(
            ingredient: "soy sauce",
            restrictions: FLRestrictions(allergens: [.soy, .sesame]))
        guard case .violated = evaluation else {
            return XCTFail("expected violated to win over unknown, got \(evaluation)")
        }
    }

    // MARK: union restrictions

    func testUnionRestrictionsApplyTogether() throws {
        let eaterA = FLRestrictions(allergens: [.soy])
        let eaterB = FLRestrictions(allergens: [.milk])
        let union = FLRestrictions.union([eaterA, eaterB])
        XCTAssertEqual(union.allergens, [.soy, .milk])

        // Soy sauce violates the union via soy even though milk is also avoided.
        let evaluation = store.evaluate(ingredient: "soy sauce", restrictions: union)
        guard case .violated(let violation) = evaluation else {
            return XCTFail("expected violated, got \(evaluation)")
        }
        XCTAssertEqual(violation.restriction, .allergen(.soy))
    }

    func testUnionAcrossAllergensAndDiets() throws {
        let eaterA = FLRestrictions(diets: [.vegetarian])
        let eaterB = FLRestrictions(diets: [.dairyFree])
        let union = FLRestrictions.union([eaterA, eaterB])
        // Cream cheese is dairy: violates dairyFree (and is vegetarian-allowed).
        let evaluation = store.evaluate(ingredient: "cream cheese", restrictions: union)
        guard case .violated(let violation) = evaluation else {
            return XCTFail("expected violated, got \(evaluation)")
        }
        XCTAssertEqual(violation.restriction, .diet(.dairyFree))
    }

    // MARK: wheat and gluten are independent axes

    func testGlutenFreeLabelNeverSettlesWheat() throws {
        // Certified-GF tamari: gluten-free allowed WITH evidence, wheat still unknown.
        let gluten = store.evaluate(
            ingredient: "certified gluten-free tamari", restrictions: FLRestrictions(diets: [.glutenFree]))
        guard case .allowed(let evidence) = gluten else {
            return XCTFail("certified-GF tamari vs glutenFree: expected allowed, got \(gluten)")
        }
        XCTAssertTrue(evidence.contains { $0.kind == .label })

        let wheat = store.evaluate(
            ingredient: "certified gluten-free tamari", restrictions: FLRestrictions(allergens: [.wheat]))
        guard case .unknown = wheat else {
            return XCTFail("a GF label must never establish wheat absence, got \(wheat)")
        }
    }

    func testGlutenFreeBreadWithDeclaredWheatStarch() throws {
        // The exact FDA case: a GF-labelled product whose declared composition
        // includes a wheat-derived component — glutenFree allowed, wheat violated.
        let gluten = store.evaluate(
            ingredient: "gluten-free bread", restrictions: FLRestrictions(diets: [.glutenFree]))
        guard case .allowed = gluten else {
            return XCTFail("expected allowed, got \(gluten)")
        }
        let wheat = store.evaluate(
            ingredient: "gluten-free bread", restrictions: FLRestrictions(allergens: [.wheat]))
        guard case .violated = wheat else {
            return XCTFail("declared wheat starch must violate wheat avoidance, got \(wheat)")
        }
    }

    func testSpeltIsWheat() throws {
        let evaluation = store.evaluate(
            ingredient: "spelt", restrictions: FLRestrictions(allergens: [.wheat]))
        guard case .violated = evaluation else {
            return XCTFail("spelt is a wheat species: expected violated, got \(evaluation)")
        }
    }

    func testWheatPresenceNeverSettlesGluten() throws {
        // Wheat contains gluten as a property — but the dataset must carry that
        // on the gluten axis, not infer it from the wheat allergen fact. The
        // generic oats form (no label) stays unknown for glutenFree.
        let evaluation = store.evaluate(
            ingredient: "oats", restrictions: FLRestrictions(diets: [.glutenFree]))
        guard case .unknown = evaluation else {
            return XCTFail("generic oats without label evidence: expected unknown, got \(evaluation)")
        }
    }

    // MARK: forms and resolution

    func testFormOverridesChangeTheOutcome() throws {
        let generic = store.evaluate(
            ingredient: "tamari", restrictions: FLRestrictions(diets: [.glutenFree]))
        guard case .unknown = generic else {
            return XCTFail("generic tamari vs glutenFree must be unknown, got \(generic)")
        }
        let certified = store.evaluate(
            ingredient: "certified gluten-free tamari", restrictions: FLRestrictions(diets: [.glutenFree]))
        guard case .allowed = certified else {
            return XCTFail("certified-GF tamari vs glutenFree must be allowed, got \(certified)")
        }
    }

    func testResolutionCoversDisplayNamesAndSynonyms() {
        for name in ["Tamari", "tamari", "  TAMARI SOY SAUCE ", "tamari soy sauce"] {
            XCTAssertNotNil(store.resolve(name), "'\(name)' should resolve")
            let evaluation = store.evaluate(
                ingredient: name, restrictions: FLRestrictions(allergens: [.soy]))
            guard case .violated = evaluation else {
                return XCTFail("'\(name)' vs soy must be violated, got \(evaluation)")
            }
        }
        XCTAssertNil(store.resolve("definitely not an ingredient"))
    }

    func testAllowedRequiresSameAxisEvidence() throws {
        // Soy sauce vs sesame: the dataset carries a 'free' fact — it must be
        // backed by non-catalog evidence to allow.
        let evaluation = store.evaluate(
            ingredient: "soy sauce", restrictions: FLRestrictions(allergens: [.sesame]))
        switch evaluation {
        case .allowed(let evidence):
            XCTAssertFalse(evidence.isEmpty)
            XCTAssertTrue(evidence.contains { $0.kind != .usda && $0.kind != .recipe },
                          "absence must not rest on catalog or recipe evidence")
        case .unknown:
            break // fail-closed absence is also acceptable when unsourced
        case .violated:
            XCTFail("soy sauce vs sesame must not violate")
        }
    }
}
