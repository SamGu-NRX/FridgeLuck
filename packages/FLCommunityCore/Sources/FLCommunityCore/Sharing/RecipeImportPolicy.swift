import Foundation
import FLDomain

// MARK: - Recipe import policy
// SPEC 3.5: ship only recipes the app has the right to ship; unknown rights
// means quarantine. Import evaluates payloads that may have been produced by
// anyone, so it never throws for policy reasons — it returns a decision:
//
// - `.accepted`    every offline-relevant right is explicitly granted and the
//                  license is not quarantined (`RecipeLicense.isQuarantined`).
// - `.quarantined` some relevant right is unknown (or attribution the license
//                  requires is missing). The revision imports but stays
//                  quarantined: private, not re-shareable, not shippable,
//                  until real rights evidence is recorded. Quarantine is
//                  curable; refusal is not.
// - `.refused`     the payload exercises a right that is explicitly forbidden,
//                  or carries content that may never travel this way at all
//                  (a LeChef draft, or a user/imported recipe with no rights
//                  declaration). Refused payloads are not stored.
//
// The refuse set is exactly {textRedistribution, offlineUseAllowed} forbidden:
// importing IS holding the text for offline use. Forbidden image or
// modification rights do not block import (no images travel in the payload;
// modification limits govern later edits, not holding the recipe) - they
// travel with the license so hosts can honor them. Caching is stricter,
// mirroring the tightened FLDomain rights rule (2026-10-11): unknown or
// forbidden caching quarantines, because a quarantined revision must not
// become the basis of offline copies.

/// Why an import was quarantined rather than accepted.
public enum RecipeQuarantineReason: String, Codable, Sendable, Equatable, CaseIterable {
    case unknownTextRights
    case unknownImageRights
    case unknownModificationRights
    case unknownCachingRights
    /// Mirrors the tightened FLDomain rights rule (2026-10-11): caching must
    /// be explicitly permitted; a forbidden right quarantines the revision.
    case forbiddenCachingRights
    case unknownOfflineRights
    /// The license requires attribution but the payload carries none; the
    /// evidence chain cannot be satisfied, so the revision cannot ship.
    case missingRequiredAttribution
}

/// Why an import was refused outright. Refused payloads are rejected at the
/// boundary and never stored.
public enum RecipeRefusalReason: String, Codable, Sendable, Equatable, CaseIterable {
    case forbiddenTextRedistribution
    case forbiddenOfflineUse
    /// LeChef drafts are private ("Made for your fridge", SPEC 3.5); they
    /// reach the catalog only through the nomination/review path.
    case lechefDraftsArePrivate
    /// Sharing always carries the author's rights declaration (SPEC 3.4).
    case missingRightsDeclaration
}

/// The outcome of evaluating one share payload.
public enum RecipeImportDecision: Equatable, Sendable {
    /// Rights are clear; the revision may enter the library normally.
    case accepted(RecipeRevision)
    /// The revision imports, but stays quarantined until rights are recorded.
    case quarantined(RecipeRevision, reasons: [RecipeQuarantineReason])
    /// The payload is not stored. The reasons are the full explanation.
    case refused(reasons: [RecipeRefusalReason])
}

/// The import evaluator. Pure: the same payload always yields the same
/// decision, and every decision is explainable from the payload's own fields.
public enum RecipeImportPolicy {
    /// Evaluate a decoded payload.
    public static func decide(_ payload: RecipeSharePayload) -> RecipeImportDecision {
        // Content that may never travel as a share, regardless of license.
        if payload.revision.key.source == .lechef {
            return .refused(reasons: [.lechefDraftsArePrivate])
        }
        // The declaration is mandatory on every share (SPEC 3.4).
        // (Export always sets it; hand-crafted payloads may omit it.)
        guard payload.declaration != nil else {
            return .refused(reasons: [.missingRightsDeclaration])
        }
        let license = payload.revision.source.license
        // The import itself redistributes text for offline use: an explicit
        // prohibition on either right refuses the payload.
        var refusals: [RecipeRefusalReason] = []
        if license.textRedistribution == .forbidden { refusals.append(.forbiddenTextRedistribution) }
        if license.offlineUseAllowed == .forbidden { refusals.append(.forbiddenOfflineUse) }
        if !refusals.isEmpty { return .refused(reasons: refusals) }

        // Unknown rights mean quarantine (SPEC 3.5) — same rule Part 1 froze
        // in `RecipeLicense.isQuarantined`, itemized here so the host can show
        // which rights are missing.
        var reasons: [RecipeQuarantineReason] = []
        if license.textRedistribution == .unknown { reasons.append(.unknownTextRights) }
        if license.imageRedistribution == .unknown { reasons.append(.unknownImageRights) }
        if license.modificationAllowed == .unknown { reasons.append(.unknownModificationRights) }
        if license.cachingAllowed == .unknown { reasons.append(.unknownCachingRights) }
        if license.cachingAllowed == .forbidden { reasons.append(.forbiddenCachingRights) }
        if license.offlineUseAllowed == .unknown { reasons.append(.unknownOfflineRights) }
        if license.attributionRequired,
           (payload.revision.source.attribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            reasons.append(.missingRequiredAttribution)
        }
        if !reasons.isEmpty {
            return .quarantined(payload.revision, reasons: reasons)
        }
        return .accepted(payload.revision)
    }

    /// Decode raw bytes and evaluate them — the full import path for untrusted
    /// data. Throws only for structurally malformed payloads or an unsupported
    /// schema version; every policy outcome is a returned decision.
    public static func decide(data: Data) throws -> RecipeImportDecision {
        let payload = try FLJSON.canonicalDecoder().decode(RecipeSharePayload.self, from: data)
        return decide(payload)
    }
}
