import XCTest
@testable import FLIngredientFacts

/// Loads the real dataset and proves the loader rejects each pinned class of
/// malformed data. Mutations address the real roots: identities.json is
/// `{ingredients: [...]}` and facts.json is `{facts: {key: entry}}`.
final class DatasetValidationTests: XCTestCase {
    func testRealDatasetLoads() throws {
        let store = try FLIngredientFactsStore(dataDirectory: DatasetLocator.datasetDirectory())
        XCTAssertGreaterThan(store.dataset.identities.count, 100)
        XCTAssertGreaterThan(store.dataset.facts.count, 200)
    }

    private func assertRejected(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ mutate: (inout JSON, inout JSON) -> Void
    ) throws {
        let directory = try DatasetMutation.withMutatedCopy(mutate)
        XCTAssertThrowsError(
            try FLIngredientFactsStore(dataDirectory: directory),
            message,
        ) { error in
            XCTAssert(
                error is FLDatasetError,
                "expected FLDatasetError, got \(error)",
            )
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: malformed JSON / vocabulary

    func testInvalidJSONRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flfacts-badjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("identities.json"))
        XCTAssertThrowsError(try FLIngredientFactsStore(dataDirectory: directory))
        try? FileManager.default.removeItem(at: directory)
    }

    func testUnknownAllergenKeyRejected() throws {
        try assertRejected("unknown allergen") { _, facts in
            facts["facts", "soy-sauce", "allergens", "sulfites"] =
                ["state": "contains", "evidence": ["kind": "standard", "ref": "x", "note": "y"]]
        }
    }

    func testUnknownDietKeyRejected() throws {
        try assertRejected("unknown diet") { _, facts in
            facts["facts", "soy-sauce", "diets", "carnivore"] =
                ["state": "violated", "evidence": ["kind": "standard", "ref": "x", "note": "y"]]
        }
    }

    func testUnknownFactStateRejected() throws {
        try assertRejected("unknown state") { _, facts in
            facts["facts", "soy-sauce", "allergens", "soy", "state"] = "maybe"
        }
    }

    func testUnknownCertaintyRejected() throws {
        try assertRejected("unknown certainty") { _, facts in
            facts["facts", "pesto", "components", 0, "certainty"] = "allegedly"
        }
    }

    func testUnresolvedComponentKeyRejected() throws {
        try assertRejected("unresolved component") { _, facts in
            facts["facts", "pesto", "components", 0, "key"] = "no-such-thing"
        }
    }

    func testEvidenceMissingRefRejected() throws {
        try assertRejected("evidence missing ref") { _, facts in
            facts["facts", "soy-sauce", "allergens", "soy", "evidence", "ref"] = NSNull()
        }
    }

    func testEvidenceMissingNoteRejected() throws {
        try assertRejected("evidence missing note") { _, facts in
            facts["facts", "soy-sauce", "allergens", "soy", "evidence", "note"] = NSNull()
        }
    }

    func testUnknownEvidenceKindRejected() throws {
        try assertRejected("unknown evidence kind") { _, facts in
            facts["facts", "soy-sauce", "allergens", "soy", "evidence", "kind"] = "rumor"
        }
    }

    // MARK: absence never rests on catalog or recipe evidence

    func testAbsenceFactWithUsdaEvidenceRejected() throws {
        try assertRejected("absence fact with usda evidence") { _, facts in
            facts["facts", "soy-sauce", "allergens", "sesame"] =
                ["state": "free", "evidence": ["kind": "usda", "ref": "174278", "note": "no sesame listed"]]
        }
    }

    func testAbsenceFactWithRecipeEvidenceRejected() throws {
        try assertRejected("absence fact with recipe evidence") { _, facts in
            facts["facts", "soy-sauce", "allergens", "sesame"] =
                ["state": "allowed", "evidence": ["kind": "recipe", "ref": "recipes/a.json#1", "note": "unused"]]
        }
    }

    // MARK: identity integrity

    func testDuplicateSynonymRejected() throws {
        // 'Soy Sauce' is the display name of another identity: the loader must
        // refuse the collision rather than silently reindexing.
        try assertRejected("duplicate synonym") { identities, _ in
            identities["ingredients", 0, "synonyms"] = ["Soy Sauce"]
        }
    }

    func testFormWithoutFactOverrideRejected() throws {
        // Declare a preparation form on an identity whose fact entry has no
        // override for it: the loader must reject the unresolved form.
        try assertRejected("form without fact override") { identities, _ in
            identities["ingredients", 0, "forms"] = [
                ["key": "form-with-no-override", "display": "Form with no override"],
            ]
        }
    }
}
