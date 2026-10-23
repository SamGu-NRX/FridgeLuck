import Foundation

/// Canonical encoding of events. Exhaustive over `EventKind`: adding a kind
/// without an encoding case fails to compile; decoding an unknown tag fails
/// closed.
public enum EventCodec {
    // MARK: Encoding

    public static func encode(_ event: TasteEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "at": .int(event.at.millisecondsSinceEpoch),
            "id": .string(event.id.rawValue),
            "kind": encodeKind(event.kind),
        ]
        object["eater"] = event.eater.map { .string($0.rawValue) } ?? .null
        object["exposure"] = event.exposure.map { exposure in
            var e: [String: JSONValue] = ["feasible": .int(Int64(exposure.feasibleCandidates))]
            e["shown"] = exposure.shownCandidates.map { .int(Int64($0)) } ?? .null
            return .object(e)
        } ?? .null
        return .object(object)
    }

    private static func encodeKind(_ kind: EventKind) -> JSONValue {
        switch kind {
        case .viewed(let recipe):
            return .object(["viewed": .object(["recipe": .string(recipe.rawValue)])])
        case .opened(let recipe):
            return .object(["opened": .object(["recipe": .string(recipe.rawValue)])])
        case .saved(let recipe):
            return .object(["saved": .object(["recipe": .string(recipe.rawValue)])])
        case .cooked(let recipe, let rating, let wouldMakeAgain):
            return .object([
                "cooked": .object([
                    "recipe": .string(recipe.rawValue),
                    "rating": rating.map { .int(Int64($0.value)) } ?? .null,
                    "wouldMakeAgain": wouldMakeAgain.map { .bool($0) } ?? .null,
                ])
            ])
        case .skipped(let recipe, let reason):
            return .object([
                "skipped": .object([
                    "recipe": .string(recipe.rawValue), "reason": .string(reason.rawValue),
                ])
            ])
        case .substituted(let recipe, let from, let to, let mode):
            return .object([
                "substituted": .object([
                    "recipe": .string(recipe.rawValue),
                    "from": .string(from.rawValue),
                    "to": to.map { .string($0.rawValue) } ?? .null,
                    "mode": mode.map { .string($0.rawValue) } ?? .null,
                ])
            ])
        case .editedServings(let recipe, let from, let to):
            return .object([
                "editedServings": .object([
                    "recipe": .string(recipe.rawValue),
                    "from": .int(Int64(from)),
                    "to": .int(Int64(to)),
                ])
            ])
        case .leChefFeedback(let recipe, let feedback):
            return .object([
                "leChefFeedback": .object([
                    "recipe": .string(recipe.rawValue),
                    "type": .string(feedback.type.rawValue),
                    "note": feedback.note.map { .string($0) } ?? .null,
                ])
            ])
        case .profileEdit(let op):
            return .object(["profileEdit": encodeProfileEdit(op)])
        case .correction(let amends, let resolution):
            return .object([
                "correction": .object([
                    "amends": .string(amends.rawValue),
                    "resolution": encodeResolution(resolution),
                ])
            ])
        }
    }

    private static func encodeProfileEdit(_ op: ProfileEditOp) -> JSONValue {
        switch op {
        case .setRestriction(let r):
            return .object([
                "setRestriction": .object([
                    "kind": .string(r.kind.rawValue),
                    "target": .string(r.target),
                    "source": .string(r.source),
                ])
            ])
        case .clearRestriction(let r):
            return .object([
                "clearRestriction": .object([
                    "kind": .string(r.kind.rawValue), "target": .string(r.target),
                ])
            ])
        case .setPreference(let feature, let polarity):
            return .object([
                "setPreference": .object([
                    "feature": .string(feature.key), "polarity": .string(polarity.rawValue),
                ])
            ])
        case .clearPreference(let feature):
            return .object(["clearPreference": .object(["feature": .string(feature.key)])])
        case .setNeverSuggest(let ingredient):
            return .object([
                "setNeverSuggest": .object(["ingredient": .string(ingredient.rawValue)])
            ])
        case .clearNeverSuggest(let ingredient):
            return .object([
                "clearNeverSuggest": .object(["ingredient": .string(ingredient.rawValue)])
            ])
        }
    }

    private static func encodeResolution(_ resolution: CorrectionResolution) -> JSONValue {
        switch resolution {
        case .void:
            return .object(["void": .null])
        case .setRating(let rating):
            return .object(["setRating": .int(Int64(rating.value))])
        case .setWouldMakeAgain(let b):
            return .object(["setWouldMakeAgain": .bool(b)])
        case .reattribute(let eater):
            return .object(["reattribute": .string(eater.rawValue)])
        }
    }

    // MARK: Decoding

    public enum DecodeError: Error, Equatable {
        case unknownKindTag(String)
        case malformedField(String)
        case invalidIdentifier(String)
        case invalidExposure
    }

    public static func decode(_ json: JSONValue) throws -> TasteEvent {
        guard case .object(let object) = json,
            case .string(let id)? = object["id"],
            let eventID = EventID(id),
            case .int(let at)? = object["at"],
            let instant = Instant(millisecondsSinceEpoch: at),
            case .object(let kind)? = object["kind"]
        else { throw DecodeError.malformedField("event") }

        let eater: EaterID?
        switch object["eater"] {
        case .string(let raw):
            guard let e = EaterID(raw) else { throw DecodeError.invalidIdentifier("eater") }
            eater = e
        case .null, .none:
            eater = nil
        default:
            throw DecodeError.malformedField("eater")
        }

        let exposure: ExposureContext?
        switch object["exposure"] {
        case .object(let e):
            guard case .int(let feasible)? = e["feasible"], feasible >= 1 else {
                throw DecodeError.invalidExposure
            }
            var shown: Int?
            switch e["shown"] {
            case .int(let s):
                guard s >= 1, s <= feasible else { throw DecodeError.invalidExposure }
                shown = Int(s)
            case .null, .none:
                shown = nil
            default:
                throw DecodeError.malformedField("exposure.shown")
            }
            guard
                let ctx = try? ExposureContext(
                    feasibleCandidates: Int(feasible), shownCandidates: shown)
            else { throw DecodeError.invalidExposure }
            exposure = ctx
        case .null, .none:
            exposure = nil
        default:
            throw DecodeError.malformedField("exposure")
        }

        guard kind.keys.count == 1, let tag = kind.keys.first, let payload = kind[tag]
        else { throw DecodeError.malformedField("kind") }

        let decodedKind = try decodeKind(tag: tag, payload: payload)
        return TasteEvent(
            id: eventID, at: instant, eater: eater, exposure: exposure, kind: decodedKind)
    }

    // MARK: Field helpers (no force-unwraps: bad ids throw)

    private static func parseString(_ json: JSONValue?, _ field: String) throws -> String {
        guard case .string(let s)? = json else { throw DecodeError.malformedField(field) }
        return s
    }

    private static func parseOptionalString(_ json: JSONValue?, _ field: String) throws -> String? {
        switch json {
        case .string(let s): return s
        case .null, .none: return nil
        default: throw DecodeError.malformedField(field)
        }
    }

    private static func parseRecipe(_ json: JSONValue?, _ field: String = "recipe") throws -> RecipeID {
        let raw = try parseString(json, field)
        guard let id = RecipeID(raw) else { throw DecodeError.invalidIdentifier(field) }
        return id
    }

    private static func parseIngredient(_ json: JSONValue?, _ field: String) throws -> IngredientID {
        let raw = try parseString(json, field)
        guard let id = IngredientID(raw) else { throw DecodeError.invalidIdentifier(field) }
        return id
    }

    private static func parseEater(_ json: JSONValue?, _ field: String) throws -> EaterID {
        let raw = try parseString(json, field)
        guard let id = EaterID(raw) else { throw DecodeError.invalidIdentifier(field) }
        return id
    }

    private static func parseKindTagged(
        _ payload: JSONValue?, _ field: String
    ) throws -> (tag: String, value: JSONValue) {
        guard case .object(let object)? = payload, object.keys.count == 1,
            let tag = object.keys.first, let value = object[tag]
        else { throw DecodeError.malformedField(field) }
        return (tag, value)
    }

    private static func decodeKind(tag: String, payload: JSONValue) throws -> EventKind {
        switch tag {
        case "viewed":
            return .viewed(recipe: try parseRecipe(payload["recipe"]))
        case "opened":
            return .opened(recipe: try parseRecipe(payload["recipe"]))
        case "saved":
            return .saved(recipe: try parseRecipe(payload["recipe"]))
        case "cooked":
            let recipe = try parseRecipe(payload["recipe"])
            let rating: Rating?
            switch payload["rating"] {
            case .int(let r): rating = Rating(Int(r))
            case .null, .none: rating = nil
            default: throw DecodeError.malformedField("cooked.rating")
            }
            let wma: Bool?
            switch payload["wouldMakeAgain"] {
            case .bool(let b): wma = b
            case .null, .none: wma = nil
            default: throw DecodeError.malformedField("cooked.wouldMakeAgain")
            }
            return .cooked(recipe: recipe, rating: rating, wouldMakeAgain: wma)
        case "skipped":
            let reasonRaw = try parseString(payload["reason"], "reason")
            guard let reason = SkipReason(rawValue: reasonRaw) else {
                throw DecodeError.malformedField("skipped.reason")
            }
            return .skipped(recipe: try parseRecipe(payload["recipe"]), reason: reason)
        case "substituted":
            let modeRaw = try parseOptionalString(payload["mode"], "mode")
            guard let modeRaw = modeRaw else {
                return .substituted(
                    recipe: try parseRecipe(payload["recipe"]),
                    from: try parseIngredient(payload["from"], "from"),
                    to: try parseOptionalString(payload["to"], "to").flatMap { IngredientID($0) },
                    mode: nil)
            }
            guard let mode = SubstitutionMode(rawValue: modeRaw) else {
                throw DecodeError.malformedField("substituted.mode")
            }
            return .substituted(
                recipe: try parseRecipe(payload["recipe"]),
                from: try parseIngredient(payload["from"], "from"),
                to: try parseOptionalString(payload["to"], "to").flatMap { IngredientID($0) },
                mode: mode)
        case "editedServings":
            guard case .int(let from)? = payload["from"], case .int(let to)? = payload["to"]
            else { throw DecodeError.malformedField("editedServings") }
            return .editedServings(
                recipe: try parseRecipe(payload["recipe"]), from: Int(from), to: Int(to))
        case "leChefFeedback":
            let typeRaw = try parseString(payload["type"], "type")
            guard let type = LeChefFeedback.FeedbackType(rawValue: typeRaw) else {
                throw DecodeError.malformedField("leChefFeedback.type")
            }
            let note = try parseOptionalString(payload["note"], "note")
            return .leChefFeedback(
                recipe: try parseRecipe(payload["recipe"]),
                feedback: LeChefFeedback(type: type, note: note))
        case "profileEdit":
            return .profileEdit(try decodeProfileEdit(payload))
        case "correction":
            let amendsRaw = try parseString(payload["amends"], "amends")
            guard let amends = EventID(amendsRaw) else {
                throw DecodeError.invalidIdentifier("amends")
            }
            let (resTag, resValue) = try parseKindTagged(
                payload["resolution"], "correction.resolution")
            let resolution: CorrectionResolution
            switch resTag {
            case "void":
                resolution = .void
            case "setRating":
                guard case .int(let r) = resValue, let rating = Rating(Int(r)) else {
                    throw DecodeError.malformedField("correction.setRating")
                }
                resolution = .setRating(rating)
            case "setWouldMakeAgain":
                guard case .bool(let b) = resValue else {
                    throw DecodeError.malformedField("correction.setWouldMakeAgain")
                }
                resolution = .setWouldMakeAgain(b)
            case "reattribute":
                resolution = .reattribute(to: try parseEater(resValue, "reattribute"))
            default:
                throw DecodeError.unknownKindTag(resTag)
            }
            return .correction(amends: amends, resolution: resolution)
        default:
            throw DecodeError.unknownKindTag(tag)
        }
    }

    private static func decodeProfileEdit(_ payload: JSONValue) throws -> ProfileEditOp {
        let (tag, value) = try parseKindTagged(payload, "profileEdit")
        switch tag {
        case "setRestriction":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("setRestriction")
            }
            let kindRaw = try parseString(r["kind"], "kind")
            guard let kind = Restriction.Kind(rawValue: kindRaw) else {
                throw DecodeError.malformedField("setRestriction.kind")
            }
            return .setRestriction(
                Restriction(
                    kind: kind, target: try parseString(r["target"], "target"),
                    source: try parseString(r["source"], "source")))
        case "clearRestriction":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("clearRestriction")
            }
            let kindRaw = try parseString(r["kind"], "kind")
            guard let kind = Restriction.Kind(rawValue: kindRaw) else {
                throw DecodeError.malformedField("clearRestriction.kind")
            }
            return .clearRestriction(
                restrictionKey: Restriction(
                    kind: kind, target: try parseString(r["target"], "target"), source: ""))
        case "setPreference":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("setPreference")
            }
            guard let key = FeatureKey(key: try parseString(r["feature"], "feature")) else {
                throw DecodeError.malformedField("setPreference.feature")
            }
            let polarityRaw = try parseString(r["polarity"], "polarity")
            guard let polarity = Polarity(rawValue: polarityRaw) else {
                throw DecodeError.malformedField("setPreference.polarity")
            }
            return .setPreference(feature: key, polarity: polarity)
        case "clearPreference":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("clearPreference")
            }
            guard let key = FeatureKey(key: try parseString(r["feature"], "feature")) else {
                throw DecodeError.malformedField("clearPreference.feature")
            }
            return .clearPreference(feature: key)
        case "setNeverSuggest":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("setNeverSuggest")
            }
            return .setNeverSuggest(ingredient: try parseIngredient(r["ingredient"], "ingredient"))
        case "clearNeverSuggest":
            guard case .object(let r) = value else {
                throw DecodeError.malformedField("clearNeverSuggest")
            }
            return .clearNeverSuggest(
                ingredient: try parseIngredient(r["ingredient"], "ingredient"))
        default:
            throw DecodeError.unknownKindTag(tag)
        }
    }
}
