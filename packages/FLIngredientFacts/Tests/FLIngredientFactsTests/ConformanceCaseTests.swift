import XCTest
@testable import FLIngredientFacts

/// Runs every shared conformance case through the real store — the same
/// contract the TypeScript and Python runners check independently.
final class ConformanceCaseTests: XCTestCase {
    struct ConformanceCase: Codable {
        var id: String
        var ingredient: String
        var restrictions: Restrictions
        var expected: Expectation
        var note: String?

        struct Restrictions: Codable {
            var allergens: [String]?
            var diets: [String]?
        }

        struct Expectation: Codable {
            var result: String
            var reasonContains: [String]?
            var missingMention: [String]?
            var evidenceMention: [String]?
        }
    }

    struct CasesFile: Codable {
        var version: Int
        var cases: [ConformanceCase]
    }

    private func loadCases() throws -> CasesFile {
        let data = try Data(contentsOf: DatasetLocator.casesFile())
        return try JSONDecoder().decode(CasesFile.self, from: data)
    }

    func testEveryConformanceCasePassesThroughTheStore() throws {
        let store = try FLIngredientFactsStore(dataDirectory: DatasetLocator.datasetDirectory())
        let cases = try loadCases().cases
        XCTAssertGreaterThanOrEqual(cases.count, 43, "the required case list must not shrink")

        var failures: [String] = []
        for c in cases {
            var restrictions = FLRestrictions()
            for a in c.restrictions.allergens ?? [] {
                if let allergen = FLAllergen(rawValue: a) { restrictions.allergens.insert(allergen) }
            }
            for d in c.restrictions.diets ?? [] {
                if let diet = FLDiet(rawValue: d) { restrictions.diets.insert(diet) }
            }
            let evaluation = store.evaluate(ingredient: c.ingredient, restrictions: restrictions)

            func check(_ problems: inout [String], _ condition: Bool, _ message: String) {
                if !condition { problems.append(message) }
            }

            var problems: [String] = []
            switch (c.expected.result, evaluation) {
            case ("allowed", .allowed(let evidence)):
                let text = evidence.map { "\($0.kind.rawValue) \($0.ref) \($0.note)".lowercased() }.joined(separator: " | ")
                for needle in c.expected.evidenceMention ?? [] {
                    check(&problems, text.lowercased().contains(needle.lowercased()),
                          "evidence does not mention '\(needle)': \(text)")
                }
            case ("violated", .violated(let violation)):
                for needle in c.expected.reasonContains ?? [] {
                    check(&problems, violation.reason.lowercased().contains(needle.lowercased()),
                          "reason does not mention '\(needle)': \(violation.reason)")
                }
            case ("unknown", .unknown(let unknown)):
                for needle in c.expected.reasonContains ?? [] {
                    check(&problems, unknown.reason.lowercased().contains(needle.lowercased()),
                          "reason does not mention '\(needle)': \(unknown.reason)")
                }
                let missing = unknown.missing.joined(separator: "; ").lowercased()
                for needle in c.expected.missingMention ?? [] {
                    check(&problems, missing.contains(needle.lowercased()),
                          "missing list does not mention '\(needle)': \(missing)")
                }
            default:
                problems.append("expected \(c.expected.result), got \(evaluation)")
            }
            for problem in problems { failures.append("\(c.id): \(problem)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
