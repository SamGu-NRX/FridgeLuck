import Foundation
import FLTaste

/// `GroundTruth` → canonical JSON. Doubles are rounded to 6 decimals before
/// serialization so the files stay readable; CanonicalJSON still guarantees
/// the exact byte format. Rounding is deterministic, so byte-identity holds.
extension GroundTruth {

    public func json() -> JSONValue {
        .object([
            "kind": .string("fltaste-sim-ground-truth"),
            "version": .int(1),
            "ranker": .string(rankerId),
            "seed": .int(Int64(bitPattern: seed)),
            "weeks": .int(Int64(weeks)),
            "householdInitial": Self.household(householdInitial, raterBias: raterBias),
            "shifts": .array(shifts.map(Self.shift)),
            "latentsOverTime": .array(latentsOverTime.map(Self.latentSnapshot)),
            "sessions": .array(sessions.map(Self.session)),
            "ratingNoiseDraws": .array(ratingNoiseDraws.map { .double(Self.round6($0)) }),
            "diagnostics": .object([
                "missedCooks": .int(Int64(missedCooks)),
                "events": .int(Int64(eventCount)),
                "cooks": .int(Int64(sessions.filter { $0.outcome == .cooked }.count)),
                "rated": .int(Int64(sessions.compactMap(\.rating).count)),
            ]),
        ])
    }

    public func jsonString() -> String {
        CanonicalJSON.encode(json())
    }

    // MARK: - Pieces

    static func household(_ household: Household, raterBias: [String: Double]) -> JSONValue {
        .object([
            "eaters": .array(
                household.eaters.map { eater in
                    .object([
                        "id": .string(eater.id.rawValue),
                        "latent": Self.latent(eater.latent),
                        "restrictions": .array(
                            eater.restrictions.map { restriction in
                                .object([
                                    "kind": .string(restriction.kind.rawValue),
                                    "target": .string(restriction.target),
                                    "source": .string(restriction.source),
                                ])
                            }),
                        "raterBias": .double(
                            Self.round6(raterBias[eater.id.rawValue] ?? 0)),
                    ])
                })
        ])
    }

    static func latent(_ vector: [Double]) -> JSONValue {
        .array(vector.map { .double(Self.round6($0)) })
    }

    static func latentSnapshot(_ snapshot: LatentSnapshot) -> JSONValue {
        var latents: [String: JSONValue] = [:]
        for (key, value) in snapshot.latents { latents[key] = Self.latent(value) }
        return .object([
            "week": .int(Int64(snapshot.week)),
            "atMillis": .int(snapshot.atMillis),
            "latents": .object(latents),
        ])
    }

    static func shift(_ record: ShiftRecord) -> JSONValue {
        var detail: [String: JSONValue] = [:]
        for (key, value) in record.detail { detail[key] = .string(value) }
        return .object([
            "week": .int(Int64(record.week)),
            "atMillis": .int(record.atMillis),
            "kind": .string(record.kind),
            "detail": .object(detail),
        ])
    }

    static func session(_ session: Session) -> JSONValue {
        var utilities: [String: JSONValue] = [:]
        for (key, value) in session.utilities { utilities[key] = .double(Self.round6(value)) }
        var probabilities: [String: JSONValue] = [:]
        for (key, value) in session.choiceProbabilities {
            probabilities[key] = .double(Self.round6(value))
        }
        var availability: [String: JSONValue] = [:]
        for (key, value) in session.availability {
            availability[key] = .double(Self.round6(value))
        }

        var object: [String: JSONValue] = [
            "week": .int(Int64(session.week)),
            "atMillis": .int(session.atMillis),
            "cookIndex": .int(Int64(session.cookIndex)),
            "actorId": .string(session.actorId),
            "feasibleIds": .array(session.feasibleIds.map { .string($0) }),
            "slateIds": .array(session.slateIds.map { .string($0) }),
            "choiceId": session.choiceId.map { .string($0) } ?? .null,
            "outcome": .string(session.outcome.rawValue),
            "trueRanking": .array(session.trueRanking.map { .string($0) }),
            "utilities": .object(utilities),
            "choiceProbabilities": .object(probabilities),
            "availability": .object(availability),
        ]
        object["rating"] = session.rating.map { rating in
            .object([
                "latentMean": .double(Self.round6(rating.latentMean)),
                "raterBias": .double(Self.round6(rating.raterBias)),
                "noise": .double(Self.round6(rating.noise)),
                "stars": .int(Int64(rating.stars)),
                "wouldMakeAgain": rating.wouldMakeAgain.map { .bool($0) } ?? .null,
            ])
        } ?? .null
        object["skip"] = session.skip.map { skip in
            .object(["recipeId": .string(skip.recipeId), "reason": .string(skip.reason)])
        } ?? .null
        object["substitution"] = session.substitution.map { sub in
            .object([
                "recipeId": .string(sub.recipeId),
                "from": .string(sub.from),
                "to": sub.to.map { .string($0) } ?? .null,
                "mode": .string(sub.mode),
            ])
        } ?? .null
        object["neverSuggestIngredient"] = session.neverSuggestIngredient.map { .string($0) }
            ?? .null
        return .object(object)
    }

    static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}
