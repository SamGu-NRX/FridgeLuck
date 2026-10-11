import XCTest
@testable import FLKitchenKnowledge

/// Loads the real data/kitchen-knowledge/ tree when the join has landed it.
/// Before the join (sub-branches not yet merged) these tests skip, so the
/// package stays green from milestone 1; after the join they enforce the
/// full contract against the real files.
final class RepositoryDataTests: XCTestCase {
    private var repoRoot: URL {
        // packages/FLKitchenKnowledge/Tests/FLKitchenKnowledgeTests/ -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FLKitchenKnowledgeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // FLKitchenKnowledge/
            .deletingLastPathComponent()  // packages/
            .deletingLastPathComponent()  // repo root
    }

    private var dataDirectory: URL {
        repoRoot.appendingPathComponent("data/kitchen-knowledge", isDirectory: true)
    }

    private func requireSubdirectory(_ relative: String) throws {
        let url = dataDirectory.appendingPathComponent(relative, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("kitchen-knowledge/\(relative) not on this branch yet (awaiting join)")
        }
    }

    func testRepositoryDataLoadsAndValidates() throws {
        try requireSubdirectory(".")
        let knowledge = try KitchenKnowledge(directory: dataDirectory)

        if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("learn-cards/cards").path) {
            XCTAssertGreaterThanOrEqual(knowledge.cards.count, 1, "learn cards must load")
            XCTAssertTrue(knowledge.cards.allSatisfy { !$0.displayName.isEmpty })

            // Every source record names a licence and a location (licensing floor).
            for card in knowledge.cards {
                for (sourceId, source) in card.sources {
                    XCTAssertFalse(source.licence.isEmpty, "\(card.id).\(sourceId) has no licence")
                    XCTAssertFalse(source.url.isEmpty, "\(card.id).\(sourceId) has no url")
                }
            }

            // The index must agree with the card files actually present.
            let index = try XCTUnwrap(knowledge.learnCardIndex, "learn-cards joined without index.json")
            XCTAssertEqual(Set(index.cards.map(\.id)), Set(knowledge.cards.map(\.id)), "index and card files disagree")

            // Core coverage is complete: every core entry in the index has a card.
            let coreIds = Set(index.cards.filter(\.isCore).map(\.id))
            XCTAssertTrue(coreIds.isSubset(of: Set(knowledge.cards.map(\.id))), "core ingredients missing cards")

            // Nutrition refusals are explicit and symmetrical: a card ships
            // without nutrition exactly when the index says so.
            let withoutNutrition = Set(knowledge.cards.filter { $0.nutritionPer100g == nil }.map(\.id))
            XCTAssertEqual(withoutNutrition, Set(index.coverage?.missingNutrition ?? []), "missingNutrition disagrees with card files")
        }
    }

    func testJoinedWasteFactorsValidate() throws {
        try requireSubdirectory("waste")
        let knowledge = try KitchenKnowledge(directory: dataDirectory)
        let catalog = try XCTUnwrap(knowledge.waste, "waste files present but failed to load")

        // Any emission factor or price present must cite something.
        for (_, factor) in catalog.emissionByIngredient {
            XCTAssertFalse(factor.citationId.isEmpty)
            XCTAssertGreaterThan(factor.kgCo2ePerKg.central, 0)
            XCTAssertLessThanOrEqual(factor.kgCo2ePerKg.low, factor.kgCo2ePerKg.high)
        }
        for (_, price) in catalog.priceByIngredient {
            XCTAssertGreaterThan(price.usdPerKg, 0)
        }

        // The twenty hand-computed examples are exercised through the ledger in
        // WasteMathTests once joined; here we check the file exists and parses.
        let examples = dataDirectory.appendingPathComponent("waste/hand_computed_examples.json")
        guard FileManager.default.fileExists(atPath: examples.path) else {
            throw XCTSkip("hand_computed_examples.json not joined yet")
        }
        let payload = try JSONDecoder().decode(
            DataEnvelope<HandComputedExamplesPayload>.self,
            from: Data(contentsOf: examples)
        )
        XCTAssertEqual(payload.data.examples.count, 20, "the model spec binds exactly twenty examples")
    }

    func testJoinedPacksLoad() throws {
        try requireSubdirectory("packs")
        let knowledge = try KitchenKnowledge(directory: dataDirectory)
        for pack in knowledge.budgetPacks {
            let sum = pack.items.compactMap(\.priceUsd).reduce(0, +)
            XCTAssertLessThanOrEqual(sum, pack.budgetUsd, "pack \(pack.id) busts its budget")
            XCTAssertEqual(sum, pack.totalCostUsd ?? sum, accuracy: 0.011, "pack \(pack.id) total mismatch")
        }
        if !knowledge.seasonalRegions.isEmpty {
            let regions = Set(knowledge.seasonalRegions.map(\.id))
            for month in knowledge.seasonalMonths {
                XCTAssertEqual(month.packs.count, regions.count, "month \(month.month) missing a region")
            }
        }
    }
}

/// Payload of data/kitchen-knowledge/waste/hand_computed_examples.json.
/// Minimal on purpose: unknown keys decode-and-ignore, so the parent can check
/// the file's shape before the full example-through-ledger assertions land.
public struct HandComputedExamplesPayload: Codable, Sendable, Equatable {
    public struct Example: Codable, Sendable, Equatable {
        public var id: String
        public var description: String?
    }

    public var examples: [Example]
}
