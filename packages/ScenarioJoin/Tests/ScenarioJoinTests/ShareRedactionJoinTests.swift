import Testing
import Foundation
import FLDomain
import FLCommunityCore
@testable import FLScenarioKit

// S5 — share export, rights, and redaction at the join (SPEC 3.4/3.5): what
// leaves the phone is a SharedCook (day-precision, no pantry, no health, no
// taste, no exact time) or a RecipeSharePayload that always carries a rights
// declaration; import classifies untrusted bytes instead of trusting them.

@Suite("S5 · Share export, redaction, and rights at the join")
struct ShareRedactionJoinTests {
    private func makeUserRecipe() throws -> RecipeRevision {
        try RecipeRevision(
            key: try RecipeKey(source: .user, sourceRecipeID: "aikos-lemon-pasta", revision: 1),
            title: "Aiko's lemon pasta",
            servingBasis: ServingBasis(servings: 2),
            ingredientLines: [Fixtures.line("l1", "lemon", 30), Fixtures.line("l2", "olive oil", 20)],
            steps: [Fixtures.step("s1", seconds: 600)],
            source: RecipeSourceEvidence(
                origin: .user,
                attribution: nil,
                license: try RecipeLicense(
                    textRedistribution: .permitted,
                    imageRedistribution: .permitted,
                    modificationAllowed: .permitted,
                    attributionRequired: false,
                    cachingAllowed: .permitted,
                    offlineUseAllowed: .permitted,
                    evidence: "author declaration recorded at import"
                )
            )
        )
    }

    /// Assembles wire bytes for a payload the app would never export — the
    /// shape a foreign or malicious sender produces (export's checked path
    /// refuses these revisions outright). Import must still classify them,
    /// so the bytes are built beside the checked path, not through it.
    private func smuggledPayload(
        revision: RecipeRevision,
        declaration: RecipeRightsDeclaration?,
        sharedAt: Date
    ) throws -> Data {
        var wire: [String: Any] = [
            "schema": RecipeSharePayload.schemaValue,
            "revision": try JSONSerialization.jsonObject(with: FLJSON.canonicalData(revision)),
            "sharedAt": FLTimestamp.encode(sharedAt),
        ]
        if let declaration {
            wire["declaration"] = [
                "kind": declaration.kind.rawValue,
                "statement": declaration.statement,
                "declaredAt": FLTimestamp.encode(declaration.declaredAt),
            ]
        }
        return try JSONSerialization.data(withJSONObject: wire)
    }

    @Test("A SharedCook leaks no pantry, health, taste, or exact-time data")
    func sharedCookRedaction() throws {
        let at = Week.day(2, hour: 19)
        let cook = try Cook(
            id: "cook-redact-1",
            recipeRevision: try RecipeKey(source: .catalog, sourceRecipeID: "r-stir", revision: 1),
            servings: 2,
            substitutions: [try CookSubstitution(from: Fixtures.ingredient("sesame oil"), to: Fixtures.ingredient("olive oil"), necessity: .necessary)],
            rating: 5,
            note: "Aiko loved it",
            startedAt: at,
            completedAt: at
        )
        let shared = try SharedCook(
            cook: cook,
            revision: Fixtures.revision("r-stir", title: "Vegetable stir-fry", lines: [
                Fixtures.line("l1", "broccoli", 300),
                Fixtures.line("l2", "sesame oil", 20),
            ]),
            completedOn: Week.dayString(for: at)
        )
        let json = try FLJSON.canonicalData(shared)
        let text = String(decoding: json, as: UTF8.self)

        // SPEC 3.4: a shared cook carries the recipe revision, servings,
        // swaps, rating, an optional one-line note, and the day. It never
        // carries the pantry (stock views, lot or household identifiers),
        // the health profile, restriction evidence, the internal cook
        // record's identity, or any exact time.
        let forbidden = ["restriction", "peanut", "allergen", "diet", "vegetarian",
                         "excluded", "totalKnownRemaining", "lastConfirmedAt",
                         "hh-", "ev-p-", "cook-redact-1", "T19:00", "T18:"]
        for term in forbidden {
            #expect(!text.lowercased().contains(term.lowercased()), "'\(term)' must never leave the phone in a SharedCook")
        }
        // And the shape that IS shared is exactly the spec's list.
        #expect(text.contains("2026-10-06"), "the day itself is exactly what is shared")
        #expect(text.lowercased().contains("aiko loved it"), "the optional note is the cook's own voice to share")
        #expect(text.contains("olive oil"), "the swap travels with its recorded necessity")
        #expect(text.contains("broccoli"), "the recipe revision travels so the recipient can cook it")
    }

    @Test("Export → bytes → import round-trips a rights-clear recipe byte for byte")
    func exportImportRoundTrip() throws {
        let revision = try makeUserRecipe()
        let user = try UserRecipe(revision: revision, updatedAt: Week.day(2, hour: 19))
        #expect(user.visibility == .private, "the default is the safe direction")

        let (published, payload) = try user.published(statement: "original recipe written by me", at: Week.day(2, hour: 20))
        #expect(published.visibility == .published)
        #expect(published.tableID == nil)

        let bytes = try payload.canonicalData()
        let decision = try RecipeImportPolicy.decide(data: bytes)
        guard case let .accepted(imported) = decision else {
            Issue.record("rights-clear payload must be accepted, got \(decision)")
            return
        }
        #expect(imported == revision, "export → bytes → import reproduces the revision exactly")
    }

    @Test("Unknown caching rights quarantine on export (nothing leaves) and on import")
    func quarantineBehavior() throws {
        // A user recipe whose rights evidence never covered caching.
        let unclear = try RecipeRevision(
            key: try RecipeKey(source: .user, sourceRecipeID: "borrowed-soup", revision: 1),
            title: "Borrowed soup",
            servingBasis: ServingBasis(servings: 2),
            ingredientLines: [Fixtures.line("l1", "tomatoes", 500)],
            steps: [Fixtures.step("s1", seconds: 300)],
            source: RecipeSourceEvidence(
                origin: .user,
                attribution: nil,
                license: try RecipeLicense(
                    textRedistribution: .permitted,
                    imageRedistribution: .unknown,
                    modificationAllowed: .permitted,
                    attributionRequired: false,
                    cachingAllowed: .unknown,
                    offlineUseAllowed: .permitted,
                    evidence: "imported with incomplete rights"
                )
            )
        )
        let user = try UserRecipe(revision: unclear, updatedAt: Week.day(2, hour: 19))

        // Export refuses to build the payload: nothing leaves the phone.
        var visibilityAfter = user
        #expect(throws: Error.self) {
            _ = try user.published(statement: "not my work", at: Week.day(2, hour: 20))
        }
        visibilityAfter = try UserRecipe(revision: unclear, updatedAt: Week.day(2, hour: 19))
        #expect(visibilityAfter.visibility == .private, "a failed export leaves visibility untouched")

        // If such a payload arrives anyway, import quarantines it with reasons.
        let payload = try smuggledPayload(
            revision: unclear,
            declaration: RecipeRightsDeclaration(kind: .haveRightsToShare, statement: "shared with the license stated in the recipe's rights evidence", declaredAt: Week.day(2, hour: 20)),
            sharedAt: Week.day(2, hour: 20)
        )
        guard case let .quarantined(imported, reasons) = try RecipeImportPolicy.decide(data: payload) else {
            Issue.record("unknown rights must quarantine")
            return
        }
        #expect(imported == unclear)
        #expect(reasons.contains(.unknownCachingRights))
        #expect(reasons.contains(.unknownImageRights))
    }

    @Test("A payload without a rights declaration is refused, not quarantined")
    func missingDeclarationIsRefusal() throws {
        let revision = try makeUserRecipe()
        let payload = try smuggledPayload(revision: revision, declaration: nil, sharedAt: Week.day(2, hour: 20))
        let decision = try RecipeImportPolicy.decide(data: payload)
        guard case let .refused(reasons) = decision else {
            Issue.record("a declaration-less payload must be refused")
            return
        }
        #expect(reasons == [.missingRightsDeclaration], "SPEC 3.4: sharing always carries the declaration")
    }

    @Test("A forbidden text right is refused outright; LeChef drafts never travel")
    func refusals() throws {
        let forbidden = try RecipeRevision(
            key: try RecipeKey(source: .user, sourceRecipeID: "no-text-rights", revision: 1),
            title: "No text rights",
            servingBasis: ServingBasis(servings: 2),
            ingredientLines: [Fixtures.line("l1", "tomatoes", 500)],
            steps: [Fixtures.step("s1", seconds: 300)],
            source: RecipeSourceEvidence(
                origin: .user,
                attribution: nil,
                license: try RecipeLicense(
                    textRedistribution: .forbidden,
                    imageRedistribution: .permitted,
                    modificationAllowed: .permitted,
                    attributionRequired: false,
                    cachingAllowed: .permitted,
                    offlineUseAllowed: .permitted,
                    evidence: "site terms forbid redistribution"
                )
            )
        )
        // Export throws at build time; import refuses the same shape.
        #expect(throws: Error.self) {
            _ = try RecipeSharePayload(
                revision: forbidden,
                declaration: RecipeRightsDeclaration(kind: .ownWork, statement: "mine", declaredAt: Week.day(2, hour: 20)),
                sharedAt: Week.day(2, hour: 20)
            )
        }
        let smuggled = try smuggledPayload(
            revision: forbidden,
            declaration: RecipeRightsDeclaration(kind: .ownWork, statement: "mine", declaredAt: Week.day(2, hour: 20)),
            sharedAt: Week.day(2, hour: 20)
        )
        guard case .refused = try RecipeImportPolicy.decide(data: smuggled) else {
            Issue.record("forbidden text rights must refuse")
            return
        }

        // A LeChef draft is private by definition.
        let draft = try RecipeRevision(
            key: try RecipeKey(source: .lechef, sourceRecipeID: "lechef-1", revision: 1),
            title: "LeChef draft",
            servingBasis: ServingBasis(servings: 2),
            ingredientLines: [],
            steps: [Fixtures.step("s1", seconds: 300)],
            source: RecipeSourceEvidence(origin: .lechef, attribution: nil, license: try RecipeLicense(
                textRedistribution: .permitted,
                imageRedistribution: .permitted,
                modificationAllowed: .permitted,
                attributionRequired: false,
                cachingAllowed: .permitted,
                offlineUseAllowed: .permitted,
                evidence: "LeChef generated"
            ))
        )
        let draftPayload = try smuggledPayload(
            revision: draft,
            declaration: RecipeRightsDeclaration(kind: .ownWork, statement: "mine", declaredAt: Week.day(2, hour: 20)),
            sharedAt: Week.day(2, hour: 20)
        )
        guard case let .refused(draftReasons) = try RecipeImportPolicy.decide(data: draftPayload) else {
            Issue.record("LeChef drafts must refuse")
            return
        }
        #expect(draftReasons.contains(.lechefDraftsArePrivate))
    }

    @Test("Visibility transitions are explicit and never widen as a side effect")
    func visibilityTransitions() throws {
        let revision = try makeUserRecipe()
        var recipe = try UserRecipe(revision: revision, updatedAt: Week.day(2, hour: 18))
        #expect(recipe.visibility == .private && recipe.tableID == nil)

        recipe = try recipe.shared(toTable: "weeknight-dinners", at: Week.day(2, hour: 18, minute: 5))
        #expect(recipe.visibility == .sharedToTable && recipe.tableID == "weeknight-dinners")

        recipe = try recipe.madePrivate(at: Week.day(2, hour: 18, minute: 10))
        #expect(recipe.visibility == .private && recipe.tableID == nil, "going private clears the Table reference")

        // A sharedToTable state without a Table name is unrepresentable.
        #expect(throws: Error.self) {
            _ = try UserRecipe(revision: revision, visibility: .sharedToTable, tableID: "  ", updatedAt: Week.day(2, hour: 19))
        }
        // tableID is only meaningful while shared.
        #expect(throws: Error.self) {
            _ = try UserRecipe(revision: revision, visibility: .private, tableID: "x", updatedAt: Week.day(2, hour: 19))
        }
    }
}
