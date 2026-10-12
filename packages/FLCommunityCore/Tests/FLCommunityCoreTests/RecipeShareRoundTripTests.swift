import XCTest
import FLDomain
@testable import FLCommunityCore

/// SPEC 3.4/3.5: the share round trip preserves the license evidence chain,
/// quarantines unknown rights and refuses forbidden ones. Every rule here is
/// frozen policy, mirrored from the tightened FLDomain rights rule of
/// 2026-10-11 (caching must be explicitly permitted).
final class RecipeShareRoundTripTests: XCTestCase {
    // MARK: Round trip preserves the evidence chain

    func testExportThenImportPreservesLicenseEvidence() throws {
        let license = try TestSupport.license(
            attributionRequired: true,
            evidence: "CC BY 4.0, recorded from the author's license page"
        )
        let sharedAt = try TestSupport.date("2026-10-11T09:30:00.000Z")
        let payload = try RecipeSharePayload(
            revision: try TestSupport.revision(
                origin: .community,
                license: license,
                attribution: "Recipe by Ama Boateng"
            ),
            declaration: try TestSupport.declaration(
                kind: .haveRightsToShare,
                declaredAt: sharedAt
            ),
            sharedAt: sharedAt
        )
        let bytes = try payload.canonicalData()
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: bytes)

        // The revision, its license grants, the attribution and the evidence
        // string all arrive unchanged.
        XCTAssertEqual(decoded.revision, payload.revision)
        XCTAssertEqual(decoded.revision.source.license.evidence, license.evidence)
        XCTAssertEqual(decoded.revision.source.license.textRedistribution, .permitted)
        XCTAssertEqual(decoded.revision.source.attribution, "Recipe by Ama Boateng")
        XCTAssertEqual(decoded.declaration?.kind, .haveRightsToShare)

        guard case let .accepted(imported) = RecipeImportPolicy.decide(decoded) else {
            return XCTFail("a fully granted payload must be accepted")
        }
        XCTAssertEqual(imported, payload.revision)
        // Byte-stable canonical form: re-encoding the decoded payload
        // reproduces the exact bytes that were shared.
        XCTAssertEqual(try FLJSON.canonicalData(decoded), bytes)
    }

    func testCanonicalFormIsStableAcrossRepeatedExport() throws {
        let payload = try TestSupport.payload(license: TestSupport.license(), sharedAt: try TestSupport.date("2026-10-11T10:00:00.000Z"))
        XCTAssertEqual(try payload.canonicalData(), try payload.canonicalData())
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: try payload.canonicalData())
        XCTAssertEqual(try decoded.canonicalData(), try payload.canonicalData())
    }

    // MARK: Export refuses what must not leave the phone

    func testExportRefusesLeChefDraft() throws {
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(), origin: .lechef, sharedAt: Date(timeIntervalSince1970: 0))) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "RecipeSharePayload.revision")
            XCTAssertTrue(reason.contains("LeChef drafts are private"), "unexpected reason: \(reason)")
        }
    }

    func testExportRefusesForbiddenTextRedistribution() throws {
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(text: .forbidden), sharedAt: Date(timeIntervalSince1970: 0)))
    }

    func testExportRefusesForbiddenOfflineUse() throws {
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(offline: .forbidden), sharedAt: Date(timeIntervalSince1970: 0)))
    }

    func testExportRefusesUnknownRights() throws {
        // SPEC 3.5: unknown rights means quarantine, and quarantined
        // revisions are not shareable.
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(text: .unknown), sharedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(modification: .unknown), sharedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(offline: .unknown), sharedAt: Date(timeIntervalSince1970: 0)))
    }

    func testExportRefusesUnknownOrForbiddenCaching() throws {
        // Tightened rule (2026-10-11): caching must be explicitly permitted.
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(caching: .unknown), sharedAt: Date(timeIntervalSince1970: 0)), "unknown caching must refuse export")
        XCTAssertThrowsError(try TestSupport.payload(license: TestSupport.license(caching: .forbidden), sharedAt: Date(timeIntervalSince1970: 0)), "forbidden caching must refuse export")
    }

    // MARK: Export refuses missing required attribution (review round 2)

    func testExportRefusesAttributionRequiredButMissing() throws {
        // Review round 2: attribution the license requires is part of the
        // evidence chain the payload claims on its face; exporting without
        // it violates the attribution condition before any recipient's
        // import check could quarantine the copy. The gate fails closed.
        let sharedAt = try TestSupport.date("2026-10-11T10:00:00.000Z")
        XCTAssertThrowsError(try RecipeSharePayload(
            revision: try TestSupport.revision(license: TestSupport.license(attributionRequired: true)),
            declaration: try TestSupport.declaration(declaredAt: sharedAt),
            sharedAt: sharedAt
        )) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "RecipeSharePayload.revision")
            XCTAssertTrue(reason.contains("attribution"), "unexpected reason: \(reason)")
        }
    }

    func testExportRefusesWhitespaceOnlyAttribution() throws {
        // Import trims before judging attribution present; export must apply
        // the same measure, not a raw nil check.
        let sharedAt = try TestSupport.date("2026-10-11T10:00:00.000Z")
        XCTAssertThrowsError(try RecipeSharePayload(
            revision: try TestSupport.revision(license: TestSupport.license(attributionRequired: true), attribution: "   "),
            declaration: try TestSupport.declaration(declaredAt: sharedAt),
            sharedAt: sharedAt
        )) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "RecipeSharePayload.revision")
            XCTAssertTrue(reason.contains("attribution"), "unexpected reason: \(reason)")
        }
    }

    // MARK: Import classifies untrusted payloads

    /// Builds a payload JSON with the given license grants and declaration
    /// presence, bypassing export policy (a sender's app may not have).
    private func payloadJSON(
        license: RecipeLicense,
        includeDeclaration: Bool = true,
        origin: RecipeSource = .community,
        attribution: String? = nil
    ) throws -> Data {
        let revision = try TestSupport.revision(origin: origin, license: license, attribution: attribution)
        let declaration = try TestSupport.declaration(declaredAt: try TestSupport.date("2026-10-11T08:00:00.000Z"))
        let payload = RecipeSharePayload(
            checkedRevision: revision,
            declaration: includeDeclaration ? declaration : nil,
            sharedAt: try TestSupport.date("2026-10-11T08:00:00.000Z")
        )
        return try FLJSON.canonicalData(payload)
    }

    func testImportQuarantinesUnknownRightsWithItemizedReasons() throws {
        let json = try payloadJSON(license: TestSupport.license(text: .unknown, caching: .unknown))
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        guard case let .quarantined(revision, reasons) = RecipeImportPolicy.decide(payload) else {
            return XCTFail("unknown rights must quarantine")
        }
        XCTAssertEqual(revision.source.license.textRedistribution, .unknown)
        XCTAssertEqual(reasons, [.unknownTextRights, .unknownCachingRights])
    }

    func testImportQuarantinesForbiddenCaching() throws {
        // Tightened rule: forbidden caching quarantines (it is not a refusal —
        // the text may still be held — but the revision must not become the
        // basis of offline copies).
        let json = try payloadJSON(license: TestSupport.license(caching: .forbidden))
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        guard case let .quarantined(_, reasons) = RecipeImportPolicy.decide(payload) else {
            return XCTFail("forbidden caching must quarantine")
        }
        XCTAssertEqual(reasons, [.forbiddenCachingRights])
    }

    func testImportRefusesMissingDeclaration() throws {
        let json = try payloadJSON(license: TestSupport.license(), includeDeclaration: false)
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        XCTAssertEqual(RecipeImportPolicy.decide(payload), .refused(reasons: [.missingRightsDeclaration]))
    }

    func testImportRefusesLeChefPayloads() throws {
        let json = try payloadJSON(license: TestSupport.license(), origin: .lechef)
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        XCTAssertEqual(RecipeImportPolicy.decide(payload), .refused(reasons: [.lechefDraftsArePrivate]))
    }

    func testImportRefusesForbiddenTextAndOfflineRights() throws {
        let json = try payloadJSON(license: TestSupport.license(text: .forbidden, offline: .forbidden))
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        XCTAssertEqual(
            RecipeImportPolicy.decide(payload),
            .refused(reasons: [.forbiddenTextRedistribution, .forbiddenOfflineUse])
        )
    }

    func testImportQuarantinesWhenAttributionRequiredButMissing() throws {
        let json = try payloadJSON(license: TestSupport.license(attributionRequired: true), attribution: nil)
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        guard case let .quarantined(_, reasons) = RecipeImportPolicy.decide(payload) else {
            return XCTFail("a required-attribution payload without attribution must quarantine")
        }
        XCTAssertEqual(reasons, [.missingRequiredAttribution])
    }

    func testImportAcceptsAttributionWhenPresent() throws {
        let json = try payloadJSON(license: TestSupport.license(attributionRequired: true), attribution: "by J. Doe")
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)
        guard case .accepted = RecipeImportPolicy.decide(payload) else {
            return XCTFail("attribution present must accept")
        }
    }

    func testImportRefusesForeignSchemaVersion() throws {
        var json = try payloadJSON(license: TestSupport.license())
        var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["schema"] = "flcommunity.v2"
        json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: json)) { error in
            guard case FLDomainError.unsupportedSchemaVersion = error else {
                return XCTFail("expected a schema error, got \(error)")
            }
        }
    }
}
