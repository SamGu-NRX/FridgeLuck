import XCTest
@testable import FLKitchenKnowledge

/// Runs every example in data/kitchen-knowledge/waste/hand_computed_examples.json
/// through the Swift WasteLedger and asserts the expected outputs exactly.
///
/// These examples are the binding acceptance test for the Swift port of the
/// waste model (data/kitchen-knowledge/waste/model.md): tools/reference.py is
/// the normative implementation, and this suite is the Swift mirror of it.
/// Any mismatch is a real defect — either the Swift ledger, the example, or
/// the reference — and must be resolved, never absorbed by a tolerance.
final class HandComputedExampleTests: XCTestCase {
    private static func dec(_ s: String) -> Decimal {
        Decimal(string: s)!
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FLKitchenKnowledgeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // FLKitchenKnowledge/
            .deletingLastPathComponent()  // packages/
            .deletingLastPathComponent()  // repo root
    }

    private var examplesURL: URL {
        repoRoot
            .appendingPathComponent("data/kitchen-knowledge/waste/hand_computed_examples.json")
    }

    // MARK: - File schema

    struct ExamplesFile: Decodable {
        var schemaVersion: Int
        var kind: String
        var retrieved: String
        var data: Payload
    }

    struct Payload: Decodable {
        var rounding: RoundingSpec
        var roundingMode: String
        var spec: String
        var examples: [Example]
    }

    struct RoundingSpec: Decodable, Equatable {
        var grams: Int
        var moneyUsd: Int
        var kgCo2e: Int
    }

    struct Example: Decodable {
        var id: String
        var description: String?
        var inputs: Inputs
        var expected: Expected
        var workings: String?
    }

    struct Inputs: Decodable {
        var events: [KitchenEvent]
        var factors: [String: FactorPair]
        var aggregates: String?
    }

    /// Example-local factors. A refusal example omits one side on purpose;
    /// each present side becomes a ledger factor.
    struct FactorPair: Decodable {
        var usdPerKg: Decimal?
        var kgCo2ePerKg: Range3?
    }

    struct Expected: Decodable {
        var savedGrams: Decimal
        var savedMoneyUsd: Decimal
        var savedKgCo2eLow: Decimal
        var savedKgCo2eCentral: Decimal
        var savedKgCo2eHigh: Decimal
        var usedLateGrams: Decimal
        var usedLateMoneyUsd: Decimal
        var usedLateKgCo2eLow: Decimal
        var usedLateKgCo2eCentral: Decimal
        var usedLateKgCo2eHigh: Decimal
        var consumedUnknownGrams: Decimal
        var consumedUnknownMoneyUsd: Decimal
        var consumedUnknownKgCo2eLow: Decimal
        var consumedUnknownKgCo2eCentral: Decimal
        var consumedUnknownKgCo2eHigh: Decimal
        var wastedGrams: Decimal
        var wastedMoneyUsd: Decimal
        var wastedKgCo2eLow: Decimal
        var wastedKgCo2eCentral: Decimal
        var wastedKgCo2eHigh: Decimal
        var notCountedGrams: Decimal
        var unpricedIngredientKeys: [String]
        var unpricedGrams: Decimal
        var missingEmissionFactorKeys: [String]
        var missingEmissionFactorGrams: Decimal
    }

    // MARK: - Loading

    private func loadFile() throws -> ExamplesFile {
        try XCTUnwrap(
            FileManager.default.contents(atPath: examplesURL.path),
            "hand_computed_examples.json exists but could not be read"
        ).pipe { try JSONDecoder().decode(ExamplesFile.self, from: $0) }
    }

    // MARK: - File-contract tests

    func testExampleFileBindsTheDocumentedRoundingAndTwentyExamples() throws {
        guard FileManager.default.fileExists(atPath: examplesURL.path) else {
            throw XCTSkip("data/kitchen-knowledge/waste not on this branch yet (awaiting join)")
        }
        let file = try loadFile()

        XCTAssertEqual(file.kind, "hand-computed-examples")
        XCTAssertEqual(file.data.examples.count, 21, "the model spec binds exactly twenty-one examples")
        XCTAssertTrue(
            file.data.roundingMode.lowercased().contains("half-up"),
            "the file must state the half-up rounding mode"
        )
        XCTAssertEqual(
            file.data.rounding,
            RoundingSpec(grams: 1, moneyUsd: 2, kgCo2e: 3),
            "the file's rounding must match WasteLedger.Rounding.standard"
        )
        XCTAssertTrue(
            file.data.examples.allSatisfy { $0.workings?.isEmpty == false },
            "every example must carry its line-by-line workings"
        )
        for example in file.data.examples where example.inputs.events.isEmpty && example.id != "ex-20" {
            XCTFail("\(example.id): empty event stream is only ex-20")
        }
    }

    // MARK: - The Swift mirror of reference.py

    func testTwentyHandComputedExamplesReproduceExactlyInSwift() throws {
        guard FileManager.default.fileExists(atPath: examplesURL.path) else {
            throw XCTSkip("data/kitchen-knowledge/waste not on this branch yet (awaiting join)")
        }
        let file = try loadFile()
        XCTAssertEqual(file.data.examples.count, 21)

        for example in file.data.examples {
            try assertExample(example, file: file)
        }
    }

    private func assertExample(_ example: Example, file: ExamplesFile) throws {
        var ledger = WasteLedger(
            prices: file.compactPrices(for: example),
            emissions: file.compactEmissions(for: example),
            rounding: WasteLedger.Rounding(
                grams: file.data.rounding.grams,
                moneyUsd: file.data.rounding.moneyUsd,
                kgCo2e: file.data.rounding.kgCo2e
            )
        )
        for event in example.inputs.events {
            ledger.record(event)
        }
        let result = ledger.result()
        let expected = example.expected
        let id = example.id

        // Bucket totals. The ledger's moneyUsd/kgCo2e are nil when no priced
        // grams fell in the bucket; the file spells that state as 0.0.
        func assertValue(_ actual: Decimal?, _ expected: Decimal, _ field: String, _ reason: String = "") {
            XCTAssertEqual(actual ?? 0, expected, "\(id).\(field)\(reason.isEmpty ? "" : ": \(reason)")")
        }
        func assertRange(_ actual: Range3?, _ low: Decimal, _ central: Decimal, _ high: Decimal, _ field: String) {
            XCTAssertEqual(actual?.low ?? 0, low, "\(id).\(field).low")
            XCTAssertEqual(actual?.central ?? 0, central, "\(id).\(field).central")
            XCTAssertEqual(actual?.high ?? 0, high, "\(id).\(field).high")
        }

        assertValue(result.saved.grams, expected.savedGrams, "savedGrams")
        assertValue(result.saved.moneyUsd, expected.savedMoneyUsd, "savedMoneyUsd")
        assertRange(result.saved.kgCo2e, expected.savedKgCo2eLow, expected.savedKgCo2eCentral, expected.savedKgCo2eHigh, "savedKgCo2e")

        assertValue(result.usedLate.grams, expected.usedLateGrams, "usedLateGrams")
        assertValue(result.usedLate.moneyUsd, expected.usedLateMoneyUsd, "usedLateMoneyUsd")
        assertRange(result.usedLate.kgCo2e, expected.usedLateKgCo2eLow, expected.usedLateKgCo2eCentral, expected.usedLateKgCo2eHigh, "usedLateKgCo2e")

        assertValue(result.consumedUnknown.grams, expected.consumedUnknownGrams, "consumedUnknownGrams")
        assertValue(result.consumedUnknown.moneyUsd, expected.consumedUnknownMoneyUsd, "consumedUnknownMoneyUsd")
        assertRange(result.consumedUnknown.kgCo2e, expected.consumedUnknownKgCo2eLow, expected.consumedUnknownKgCo2eCentral, expected.consumedUnknownKgCo2eHigh, "consumedUnknownKgCo2e")

        assertValue(result.wasted.grams, expected.wastedGrams, "wastedGrams")
        assertValue(result.wasted.moneyUsd, expected.wastedMoneyUsd, "wastedMoneyUsd")
        assertRange(result.wasted.kgCo2e, expected.wastedKgCo2eLow, expected.wastedKgCo2eCentral, expected.wastedKgCo2eHigh, "wastedKgCo2e")

        assertValue(result.notCounted.grams, expected.notCountedGrams, "notCountedGrams")

        // Refusals, per reason: the binding shape is the ledger's own totals
        // (model.md §5–6) — the refused key sets plus grams summed unrounded
        // and rounded once — checked against the example's binding values,
        // never against the rounded per-ingredient rows.
        XCTAssertEqual(
            result.unpricedIngredientKeys.sorted(),
            expected.unpricedIngredientKeys.sorted(),
            "\(id).unpricedIngredientKeys: got \(result.unpricedIngredientKeys)"
        )
        XCTAssertEqual(result.unpricedGrams, expected.unpricedGrams, "\(id).unpricedGrams")

        XCTAssertEqual(
            result.missingEmissionFactorKeys.sorted(),
            expected.missingEmissionFactorKeys.sorted(),
            "\(id).missingEmissionFactorKeys: got \(result.missingEmissionFactorKeys)"
        )
        XCTAssertEqual(
            result.missingEmissionFactorGrams, expected.missingEmissionFactorGrams,
            "\(id).missingEmissionFactorGrams"
        )

        // The per-(ingredient, reason) detail rows describe the same refusal
        // sets as the binding totals.
        XCTAssertEqual(
            Set(result.refusals.filter { $0.reason == .missingPrice }.map(\.ingredientKey)),
            Set(expected.unpricedIngredientKeys),
            "\(id).unpriced detail rows"
        )
        XCTAssertEqual(
            Set(result.refusals.filter { $0.reason == .missingEmissionFactor }.map(\.ingredientKey)),
            Set(expected.missingEmissionFactorKeys),
            "\(id).missingEmissionFactor detail rows"
        )
    }
}

// MARK: - Factor plumbing

extension HandComputedExampleTests.ExamplesFile {
    /// The example's price rows as ledger factors (only keys that carry one).
    func compactPrices(for example: HandComputedExampleTests.Example) -> [PriceFactor] {
        example.inputs.factors.compactMap { key, pair in
            pair.usdPerKg.map {
                PriceFactor(
                    ingredientKey: key, usdPerKg: $0,
                    displayQuantity: nil, displayPriceUsd: nil, sourceSeries: nil,
                    citationId: "example-\(example.id)"
                )
            }
        }
    }

    /// The example's emission rows as ledger factors (only keys that carry one).
    func compactEmissions(for example: HandComputedExampleTests.Example) -> [EmissionFactor] {
        example.inputs.factors.compactMap { key, pair in
            pair.kgCo2ePerKg.map {
                EmissionFactor(
                    ingredientKey: key, owidEntity: nil, kgCo2ePerKg: $0,
                    citationId: "example-\(example.id)"
                )
            }
        }
    }
}

extension Data {
    func pipe<T>(_ transform: (Data) throws -> T) rethrows -> T {
        try transform(self)
    }
}
