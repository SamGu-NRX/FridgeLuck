import XCTest
import FLDomain
@testable import FLCommunityCore

/// User recipes are household-authored and private by default (SPEC 3.4/3.5).
/// The tests freeze: the private default, the explicit-transition-only state
/// model, Table naming, and the publication path building its payload under
/// the same export policy as sharing — own-work declaration, forbidden
/// refusal, explicit-caching requirement, evidence-chain round trip, and a
/// wire shape that carries no household fields.
final class UserRecipeTests: XCTestCase {
    // MARK: Helpers

    private func authoredRevision(
        slug: String = "household-dal",
        license: RecipeLicense,
        attribution: String? = "Recipe by the household"
    ) throws -> RecipeRevision {
        try TestSupport.revision(slug: slug, license: license, attribution: attribution)
    }

    private func authorRecipe(
        _ revision: RecipeRevision,
        visibility: UserRecipeVisibility = .private,
        tableID: String? = nil,
        at iso: String = "2026-10-11T08:00:00.000Z"
    ) throws -> UserRecipe {
        try UserRecipe(revision: revision, visibility: visibility, tableID: tableID, updatedAt: try TestSupport.date(iso))
    }

    private func assertValidation(
        target: String,
        reasonContains: String? = nil,
        _ body: () throws -> Void
    ) throws {
        XCTAssertThrowsError(try body()) { error in
            guard case let FLDomainError.validation(actualTarget, reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(actualTarget, target)
            if let reasonContains {
                XCTAssertTrue(reason.contains(reasonContains), "unexpected reason: \(reason)")
            }
        }
    }

    // MARK: The private default

    func testNewUserRecipesArePrivateByDefault() throws {
        let recipe = try authorRecipe(try authoredRevision(license: TestSupport.license()))
        XCTAssertEqual(recipe.visibility, .private)
        XCTAssertNil(recipe.tableID)
    }

    func testRefusesRevisionsThatAreNotHouseholdAuthored() throws {
        for origin in [RecipeSource.community, .lechef] {
            let revision = try TestSupport.revision(origin: origin, license: TestSupport.license())
            try assertValidation(target: "UserRecipe.revision", reasonContains: "source: .user") {
                _ = try authorRecipe(revision)
            }
        }
    }

    // MARK: Table sharing

    func testSharingToATableRequiresItsName() throws {
        let revision = try authoredRevision(license: TestSupport.license())
        try assertValidation(target: "UserRecipe.tableID", reasonContains: "names its Table") {
            _ = try authorRecipe(revision, visibility: .sharedToTable, tableID: nil)
        }
        try assertValidation(target: "UserRecipe.tableID", reasonContains: "names its Table") {
            _ = try authorRecipe(revision, visibility: .sharedToTable, tableID: "   ")
        }
    }

    func testTableReferenceIsForbiddenOutsideTableSharing() throws {
        let revision = try authoredRevision(license: TestSupport.license())
        try assertValidation(target: "UserRecipe.tableID", reasonContains: "only meaningful") {
            _ = try authorRecipe(revision, visibility: .private, tableID: "table-7")
        }
        try assertValidation(target: "UserRecipe.tableID", reasonContains: "only meaningful") {
            _ = try authorRecipe(revision, visibility: .published, tableID: "table-7")
        }
    }

    func testSharingReturnsNewValueAndLeavesTheOriginalPrivate() throws {
        let recipe = try authorRecipe(try authoredRevision(license: TestSupport.license()))
        let shared = try recipe.shared(toTable: "  thursday-cooks  ", at: try TestSupport.date("2026-10-11T09:00:00.000Z"))
        XCTAssertEqual(recipe.visibility, .private, "the original value is untouched")
        XCTAssertNil(recipe.tableID)
        XCTAssertEqual(shared.visibility, .sharedToTable)
        XCTAssertEqual(shared.tableID, "thursday-cooks", "the Table name is trimmed")
        XCTAssertEqual(shared.updatedAt, try TestSupport.date("2026-10-11T09:00:00.000Z"))
    }

    func testMakingPrivateClearsTheTableReference() throws {
        let recipe = try authorRecipe(try authoredRevision(license: TestSupport.license()))
        let shared = try recipe.shared(toTable: "thursday-cooks", at: try TestSupport.date("2026-10-11T09:00:00.000Z"))
        let backToPrivate = try shared.madePrivate(at: try TestSupport.date("2026-10-11T10:00:00.000Z"))
        XCTAssertEqual(backToPrivate.visibility, .private)
        XCTAssertNil(backToPrivate.tableID)
        XCTAssertEqual(backToPrivate.revision, recipe.revision, "the revision and its evidence are untouched")
    }

    // MARK: Publishing

    func testPublishingProducesPublishedStateAndOwnWorkPayload() throws {
        let revision = try authoredRevision(license: TestSupport.license())
        let recipe = try authorRecipe(revision)
        let (published, payload) = try recipe.published(
            statement: "original recipe written by our household",
            at: try TestSupport.date("2026-10-11T11:00:00.000Z")
        )
        XCTAssertEqual(published.visibility, .published)
        XCTAssertNil(published.tableID)
        XCTAssertEqual(published.revision, revision, "publishing never rewrites the revision")
        XCTAssertEqual(payload.declaration?.kind, .ownWork)
        XCTAssertEqual(payload.declaration?.statement, "original recipe written by our household")
        XCTAssertEqual(payload.sharedAt, try TestSupport.date("2026-10-11T11:00:00.000Z"))
    }

    func testPublishingRefusesForbiddenTextRights() throws {
        let recipe = try authorRecipe(try authoredRevision(
            license: TestSupport.license(text: .forbidden, evidence: "all rights reserved by the author")
        ))
        try assertValidation(target: "RecipeSharePayload.revision", reasonContains: "forbidden") {
            _ = try recipe.published(statement: "mine", at: try TestSupport.date("2026-10-11T11:00:00.000Z"))
        }
    }

    func testPublishingRefusesCachingThatIsNotExplicitlyPermitted() throws {
        for caching in [RecipeLicense.Grant.unknown, .forbidden] {
            let recipe = try authorRecipe(try authoredRevision(
                license: TestSupport.license(caching: caching, evidence: "author grant with withheld caching")
            ))
            try assertValidation(target: "RecipeSharePayload.revision", reasonContains: "caching must be explicitly permitted") {
                _ = try recipe.published(statement: "mine", at: try TestSupport.date("2026-10-11T11:00:00.000Z"))
            }
        }
    }

    func testPublishedPayloadRoundTripsTheEvidenceChain() throws {
        let revision = try authoredRevision(
            license: TestSupport.license(attributionRequired: true, evidence: "household original, recorded by the author")
        )
        let recipe = try authorRecipe(revision)
        let (_, payload) = try recipe.published(statement: "our household original", at: try TestSupport.date("2026-10-11T11:00:00.000Z"))
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: try payload.canonicalData())
        XCTAssertEqual(decoded.revision, revision, "export → bytes → import preserves the revision byte for byte")
        XCTAssertEqual(decoded.declaration?.kind, .ownWork)
        XCTAssertEqual(payload.schema, FLCommunitySchema.acceptedMajor)
    }

    /// The redaction assertion at the wire level: the published payload's
    /// encoded key set is exactly the four contract keys — no household
    /// fields (tableID, updatedAt) can attach, now that they are not fields.
    func testPublishedPayloadCarriesNoHouseholdFields() throws {
        let recipe = try authorRecipe(try authoredRevision(license: TestSupport.license()))
        let (_, payload) = try recipe.published(statement: "ours", at: try TestSupport.date("2026-10-11T11:00:00.000Z"))
        let object = try JSONSerialization.jsonObject(with: try payload.canonicalData()) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys ?? [:].keys),
            ["schema", "revision", "declaration", "sharedAt"],
            "the publication wire shape is frozen: no household fields"
        )
    }

    func testPublishingWithoutARightsStatementThrows() throws {
        let recipe = try authorRecipe(try authoredRevision(license: TestSupport.license()))
        try assertValidation(target: "RecipeRightsDeclaration.statement", reasonContains: "not evidence") {
            _ = try recipe.published(statement: "   ", at: try TestSupport.date("2026-10-11T11:00:00.000Z"))
        }
    }
}
