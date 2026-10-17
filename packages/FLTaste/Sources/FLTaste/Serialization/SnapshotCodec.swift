import Foundation

/// Versioned, canonical snapshot of everything durable in the engine: the
/// append-only event log plus the configuration that produced the fold.
///
/// Model state is event-sourced: the folded state is always exactly
/// `Fold.apply(log)` (a tested invariant), so the snapshot needs no
/// duplicated derived fields. Restore parses, migrates forward, checks
/// feature-space identity, and re-folds.
public enum SnapshotCodec {
    public static let currentFormatVersion = 1

    public enum SnapshotError: Error, Equatable {
        case notAnObject
        case missingField(String)
        case unknownFormatVersion(Int)
        case featureSpaceMismatch(snapshot: String, engine: String)
        case unknownConfigVersion(Int)
        case malformedEvents
    }

    public static func encode(_ events: [TasteEvent], config: TasteConfig) -> JSONValue {
        // Events serialize in canonical order (timestamp, id) so identical
        // logical logs give identical bytes.
        let ordered = events.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
        return .object([
            "config": encodeConfig(config),
            "events": .array(ordered.map { EventCodec.encode($0) }),
            "featureSpaceVersion": .string(tasteFeaturesVersion),
            "formatVersion": .int(Int64(currentFormatVersion)),
        ])
    }

    public static func decode(
        _ json: JSONValue, featureSpaceVersion expected: String
    ) throws -> (events: [TasteEvent], config: TasteConfig) {
        guard case .object(let object) = json else { throw SnapshotError.notAnObject }
        guard case .int(let version)? = object["formatVersion"] else {
            throw SnapshotError.missingField("formatVersion")
        }
        guard version >= 1 && version <= Int(currentFormatVersion) else {
            throw SnapshotError.unknownFormatVersion(Int(version))
        }
        let migrated = try SnapshotMigrations.forwardApply(
            json, toVersion: Int(currentFormatVersion))
        guard case .object(let migratedObject) = migrated else {
            throw SnapshotError.notAnObject
        }
        guard
            case .string(let features)? = migratedObject["featureSpaceVersion"],
            features == expected
        else {
            let found: String
            if case .string(let f)? = migratedObject["featureSpaceVersion"] {
                found = f
            } else {
                found = "missing"
            }
            throw SnapshotError.featureSpaceMismatch(snapshot: found, engine: expected)
        }
        let config = try decodeConfig(migratedObject["config"])
        guard case .array(let eventArray)? = migratedObject["events"] else {
            throw SnapshotError.malformedEvents
        }
        let events = try eventArray.map { try EventCodec.decode($0) }
        return (events, config)
    }

    // MARK: Config

    private static func encodeConfig(_ config: TasteConfig) -> JSONValue {
        .object([
            "coldStartEvidence": .double(config.coldStartEvidence),
            "cookedEvidenceHalfLifeDays": .double(config.cookedEvidenceHalfLifeDays),
            "exposureFloor": .double(config.exposureFloor),
            "explorationDecayEvidence": .double(config.explorationDecayEvidence),
            "explorationInflation": .double(config.explorationInflation),
            "feedbackEvidenceHalfLifeDays": .double(config.feedbackEvidenceHalfLifeDays),
            "openedEvidenceHalfLifeDays": .double(config.openedEvidenceHalfLifeDays),
            "observationNoiseVariance": .double(config.observationNoiseVariance),
            "pantryFitWeight": .double(config.pantryFitWeight),
            "popularityWeight": .double(config.popularityWeight),
            "posteriorHalfLifeDays": .double(config.posteriorHalfLifeDays),
            "priorWeightVariance": .double(config.priorWeightVariance),
            "repeatAffinityHalfLifeDays": .double(config.repeatAffinityHalfLifeDays),
            "repeatAffinityWeight": .double(config.repeatAffinityWeight),
            "savedEvidenceHalfLifeDays": .double(config.savedEvidenceHalfLifeDays),
            "skippedEvidenceHalfLifeDays": .double(config.skippedEvidenceHalfLifeDays),
            "softDismissalExpiryDays": .int(config.softDismissalExpiryDays),
            "substitutionEvidenceHalfLifeDays": .double(config.substitutionEvidenceHalfLifeDays),
            "configVersion": .int(Int64(config.configVersion)),
            "viewedEvidenceHalfLifeDays": .double(config.viewedEvidenceHalfLifeDays),
        ])
    }

    private static func decodeConfig(_ json: JSONValue?) throws -> TasteConfig {
        guard case .object(let object)? = json else { throw SnapshotError.missingField("config") }
        guard case .int(let version)? = object["configVersion"] else {
            throw SnapshotError.missingField("configVersion")
        }
        guard version == 1 else { throw SnapshotError.unknownConfigVersion(Int(version)) }

        func double(_ key: String) throws -> Double {
            guard case .double(let d)? = object[key] else {
                throw SnapshotError.missingField("config.\(key)")
            }
            return d
        }
        func int64(_ key: String) throws -> Int64 {
            guard case .int(let i)? = object[key] else {
                throw SnapshotError.missingField("config.\(key)")
            }
            return i
        }

        return TasteConfig(
            configVersion: Int(version),
            posteriorHalfLifeDays: try double("posteriorHalfLifeDays"),
            cookedEvidenceHalfLifeDays: try double("cookedEvidenceHalfLifeDays"),
            savedEvidenceHalfLifeDays: try double("savedEvidenceHalfLifeDays"),
            openedEvidenceHalfLifeDays: try double("openedEvidenceHalfLifeDays"),
            viewedEvidenceHalfLifeDays: try double("viewedEvidenceHalfLifeDays"),
            skippedEvidenceHalfLifeDays: try double("skippedEvidenceHalfLifeDays"),
            substitutionEvidenceHalfLifeDays: try double("substitutionEvidenceHalfLifeDays"),
            feedbackEvidenceHalfLifeDays: try double("feedbackEvidenceHalfLifeDays"),
            exposureFloor: try double("exposureFloor"),
            observationNoiseVariance: try double("observationNoiseVariance"),
            priorWeightVariance: try double("priorWeightVariance"),
            pantryFitWeight: try double("pantryFitWeight"),
            popularityWeight: try double("popularityWeight"),
            explorationInflation: try double("explorationInflation"),
            explorationDecayEvidence: try double("explorationDecayEvidence"),
            coldStartEvidence: try double("coldStartEvidence"),
            repeatAffinityWeight: try double("repeatAffinityWeight"),
            repeatAffinityHalfLifeDays: try double("repeatAffinityHalfLifeDays"),
            softDismissalExpiryDays: try int64("softDismissalExpiryDays"))
    }
}

/// Forward-only migration registry. Each step rewrites a snapshot document
/// from format version n to n+1. Restoring an older format walks the steps in
/// order; restoring a newer format than the code knows fails closed.
public enum SnapshotMigrations {
    /// Registered steps, keyed by the version they upgrade FROM. When format
    /// v2 lands (M2), its step (and the v1->v2 golden fixture) is registered
    /// here. v1 is the base.
    private static let steps: [Int: @Sendable (JSONValue) throws -> JSONValue] = [:]

    public static func forwardApply(_ json: JSONValue, toVersion target: Int) throws -> JSONValue {
        var document = json
        guard case .object(let object) = document,
            case .int(let version)? = object["formatVersion"]
        else {
            throw SnapshotCodec.SnapshotError.notAnObject
        }
        var current = Int(version)
        while current < target {
            guard let step = steps[current] else {
                // No registered step for this boundary: adjacent versions
                // whose shapes agree (identity migration). Unknown future
                // versions never get here — decode's range check fails first.
                current += 1
                continue
            }
            document = try step(document)
            current += 1
        }
        return document
    }
}
