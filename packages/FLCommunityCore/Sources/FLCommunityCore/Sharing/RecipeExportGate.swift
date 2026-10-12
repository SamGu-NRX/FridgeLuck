import FLDomain

// MARK: - The export gate
// SPEC 3.5: sharing redistributes a recipe's text for offline use. A
// revision may leave the phone only when its recorded rights say so. Both
// payload types that embed the full revision text — `RecipeSharePayload`
// and `SharedCook` — enforce this gate at construction, because an
// unauthorized export cannot be undone by any recipient-side import check.
// `SharedCook` additionally gates its decode and its outgoing `encode(to:)`:
// every embedded revision passes the policy entering the phone, leaving it,
// and being built — no unvalidated pass-through in either direction.
// Every check fails closed: missing or unknown rights block the payload
// rather than pass it.

/// The export policy every outgoing payload passes: LeChef drafts are
/// private, forbidden text or offline rights refuse, unknown rights mean
/// quarantine (and quarantined revisions are not re-shareable), caching
/// must be explicitly permitted, and attribution the license requires must
/// actually be recorded on the revision.
///
/// The refusal and quarantine sets mirror what `RecipeImportPolicy` would
/// never accept on the receiving side — export refuses it first.
public enum RecipeExportGate {
    /// The reason the revision may not leave the phone, or `nil` when it may.
    public static func exportBlocker(for revision: RecipeRevision) -> String? {
        if revision.key.source == .lechef {
            return "LeChef drafts are private ('Made for your fridge') and cannot be shared; nominate via review instead"
        }
        let license = revision.source.license
        if license.textRedistribution == .forbidden || license.offlineUseAllowed == .forbidden {
            return "sharing redistributes the text for offline use, and that right is forbidden for this revision"
        }
        // Quarantine set mirrors the tightened FLDomain rights rule
        // (2026-10-11): unknown rights on text, modification or offline use
        // quarantine, and offline caching requires cachingAllowed == .permitted
        // explicitly, so unknown or forbidden caching quarantines too.
        if license.textRedistribution == .unknown
            || license.modificationAllowed == .unknown
            || license.offlineUseAllowed == .unknown
            || license.cachingAllowed != .permitted {
            return "revision is quarantined (unknown rights mean quarantine, SPEC 3.5; caching must be explicitly permitted); record the rights before sharing"
        }
        if license.attributionRequired,
            (revision.source.attribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            return "the license requires attribution but the revision carries none; record the attribution before sharing (import quarantines such a copy as missingRequiredAttribution)"
        }
        return nil
    }

    /// Throws unless the revision may leave the phone. `target` names the
    /// enforcing type so the error reads `<Type>.revision` at the call site.
    public static func validateExportable(_ revision: RecipeRevision, target: String) throws {
        if let blocker = exportBlocker(for: revision) {
            throw FLDomainError.validation(target: target, reason: blocker)
        }
    }
}
