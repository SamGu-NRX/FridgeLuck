import Foundation

/// The human-readable taste profile (SPEC 3.3): sentences with evidence,
/// denominators and recency, each editable through exact profile-edit
/// operations so "this is wrong" / "don't ask again" / reopen are
/// predictable state changes, not guesswork.
///
/// Every number in a sentence is read from folded state — never templated.
/// Sentence policy (SENTENCE-POLICY in DESIGN.md):
/// - explicit layers render as-is (restrictions, never-suggest, stated);
/// - learned ingredient sentences need >=3 supporting cooks, >=60% agreement,
///   and live evidence (decayed weight of the last event >= 1/8);
/// - "don't ask again" is soft and expires (`softDismissalExpiryDays`);
///   "this is wrong" pins a stated preference that beats inference.
public struct TasteProfile: Equatable, Sendable {
    public static let version = "taste-profile-v1"

    public let version: String
    public let generatedAt: Instant
    /// Stable order: restrictions, never-suggest, stated, learned; each
    /// group sorted by sentence id.
    public let sentences: [ProfileSentence]
}

public struct ProfileSentence: Equatable, Sendable {
    public enum Provenance: Equatable, Sendable {
        /// Inferred from behaviour; expires as its evidence decays.
        case learned
        /// Explicitly stated; beats any learned frequency until reopened.
        case stated
        /// "Don't ask again" — soft, expires.
        case neverSuggest
        /// Allergy/diet — hard filter, survives any model reset.
        case restriction
    }

    /// Stable across regenerations, so the app can address edits at it.
    public let id: String
    public let text: String
    public let provenance: Provenance
    /// The feature this sentence acts on, when it has one.
    public let feature: FeatureKey?
    /// The ingredient this sentence acts on, when it has one.
    public let ingredient: IngredientID?
    public let evidence: Evidence
    /// The exact edits the app can offer. Applying one as a `profileEdit`
    /// event changes rankings immediately (tested, documented direction).
    public let edits: Edits

    public struct Edits: Equatable, Sendable {
        /// "This is wrong" — a strong correction: pins the opposite stated
        /// preference, which the model treats as high-weight evidence.
        public let thisIsWrong: ProfileEditOp?
        /// "Don't ask again" — soft: hides related recipes until it expires.
        public let dontAskAgain: ProfileEditOp?
        /// Reopen: removes the explicit state behind the sentence. Changing
        /// your mind never requires a full reset.
        public let reopen: ProfileEditOp?

        public init(thisIsWrong: ProfileEditOp?, dontAskAgain: ProfileEditOp?, reopen: ProfileEditOp?) {
            self.thisIsWrong = thisIsWrong
            self.dontAskAgain = dontAskAgain
            self.reopen = reopen
        }
    }
}

public struct Evidence: Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int
    public let lastSeen: Instant?
    /// Attribution ("household", "eater sam") — what the counts describe.
    public let note: String

    public init(numerator: Int, denominator: Int, lastSeen: Instant?, note: String) {
        self.numerator = numerator
        self.denominator = denominator
        self.lastSeen = lastSeen
        self.note = note
    }
}

/// Pure sentence generation from folded state. Same state + same `now`
/// produce the same profile (tested).
public enum ProfileBuilder {
    public static func build(
        state: EngineState, catalog: RecipeCatalog, config: TasteConfig, now: Instant
    ) -> TasteProfile {
        var sentences: [ProfileSentence] = []
        sentences.append(contentsOf: restrictionSentences(state: state))
        sentences.append(contentsOf: neverSuggestSentences(state: state, config: config, now: now))
        sentences.append(contentsOf: statedSentences(state: state, now: now))
        for eaterID in state.eaters.keys.sorted() {
            guard let eater = state.eaters[eaterID] else { continue }
            sentences.append(
                contentsOf: learnedSentences(
                    eaterID: eaterID, eater: eater, householdStated: state.household.stated,
                    catalog: catalog, config: config, now: now))
        }
        return TasteProfile(
            version: TasteProfile.version, generatedAt: now, sentences: sentences)
    }

    // MARK: Explicit sentences

    private static func restrictionSentences(state: EngineState) -> [ProfileSentence] {
        func sentence(_ restriction: Restriction, source: String) -> ProfileSentence {
            let kindWord = restriction.kind == .allergy ? "Allergy" : "Diet"
            let name = displayName(restriction.target)
            return ProfileSentence(
                id: "restriction.\(restriction.kind.rawValue).\(restriction.target)",
                text: "\(kindWord): \(name) — always excluded.",
                provenance: .restriction, feature: nil,
                ingredient: IngredientID(restriction.target),
                evidence: Evidence(numerator: 0, denominator: 0, lastSeen: nil, note: source),
                edits: .init(thisIsWrong: nil, dontAskAgain: nil, reopen: .clearRestriction(restrictionKey: restriction)))
        }
        var result = state.household.restrictions.map { sentence($0, source: "household") }
        for eaterID in state.eaters.keys.sorted() {
            let source = "eater \(eaterID.rawValue)"
            result += (state.eaters[eaterID]?.explicit.restrictions ?? []).map {
                sentence($0, source: source)
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func neverSuggestSentences(
        state: EngineState, config: TasteConfig, now: Instant
    ) -> [ProfileSentence] {
        func sentence(
            _ ingredient: IngredientID, _ record: ExplicitLayer.NeverSuggestRecord, source: String
        ) -> ProfileSentence? {
            // Expired requests no longer act (the ranker unblocks them), so
            // they stop rendering as well.
            let age = Double(record.addedAt.days(to: now))
            guard age >= 0, age < Double(config.softDismissalExpiryDays) else { return nil }
            let expiresAt = Instant(
                Date(
                    timeIntervalSince1970: Double(
                        record.addedAt.millisecondsSinceEpoch + config.softDismissalExpiryDays * 86_400_000)
                        / 1000))
            let name = displayName(ingredient.rawValue)
            return ProfileSentence(
                id: "neversuggest.ingredient.\(ingredient.rawValue)",
                text:
                    "You asked us not to suggest \(name) — that request expires on \(expiresAt.iso8601UTC).",
                provenance: .neverSuggest, feature: nil, ingredient: ingredient,
                evidence: Evidence(numerator: 0, denominator: 0, lastSeen: record.addedAt, note: source),
                edits: .init(
                    thisIsWrong: nil, dontAskAgain: nil,
                    reopen: .clearNeverSuggest(ingredient: ingredient)))
        }
        var result: [ProfileSentence] = []
        for (ingredient, record) in state.household.neverSuggest.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let s = sentence(ingredient, record, source: "household") { result.append(s) }
        }
        for eaterID in state.eaters.keys.sorted() {
            for (ingredient, record) in (state.eaters[eaterID]?.explicit.neverSuggest ?? [:])
                .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            {
                if let s = sentence(ingredient, record, source: "eater \(eaterID.rawValue)") {
                    result.append(s)
                }
            }
        }
        return result
    }

    private static func statedSentences(state: EngineState, now: Instant) -> [ProfileSentence] {
        func sentence(
            _ feature: FeatureKey, _ stated: ExplicitLayer.StatedPreference, source: String
        ) -> ProfileSentence {
            let subject = displayName(feature.value)
            let verb = stated.polarity == .like ? "you like" : "you would rather not have"
            return ProfileSentence(
                id: "stated.\(feature.namespace).\(feature.value)",
                text: "You told us: \(verb) \(subject) (\(recency(stated.addedAt, now: now)), \(source)).",
                provenance: .stated, feature: feature,
                ingredient: feature.namespace == "ingredient" ? IngredientID(feature.value) : nil,
                evidence: Evidence(numerator: 1, denominator: 1, lastSeen: stated.addedAt, note: source),
                edits: .init(thisIsWrong: nil, dontAskAgain: nil, reopen: .clearPreference(feature: feature)))
        }
        var result = state.household.stated.sorted(by: { $0.key < $1.key }).map {
            sentence($0.key, $0.value, source: "household")
        }
        for eaterID in state.eaters.keys.sorted() {
            let source = "eater \(eaterID.rawValue)"
            result += (state.eaters[eaterID]?.explicit.stated ?? [:])
                .sorted(by: { $0.key < $1.key }).map {
                    sentence($0.key, $0.value, source: source)
                }
        }
        return result
    }

    // MARK: Learned sentences

    private static func learnedSentences(
        eaterID: EaterID, eater: EaterState,
        householdStated: [FeatureKey: ExplicitLayer.StatedPreference],
        catalog: RecipeCatalog, config: TasteConfig,
        now: Instant
    ) -> [ProfileSentence] {
        var sentences: [ProfileSentence] = []
        var cookCounts: [String: (positive: Int, total: Int, last: Instant?)] = [:]
        var removeCounts: [String: (positive: Int, total: Int, last: Instant?)] = [:]
        var timeCounts: [String: (positive: Int, total: Int, last: Instant?)] = [:]
        let extractor = FeatureExtractor(catalog: catalog)

        for (recipeID, history) in eater.recipeHistory {
            guard let recipe = catalog.recipes[recipeID] else { continue }
            let vector = extractor.extract(recipe, catalog: catalog)
            var ingredientIDs = Set<String>()
            var timeBucket: String?
            for component in vector.components {
                guard let key = extractor.space.key(at: component.index) else { continue }
                if key.namespace == "ingredient", component.value >= 1.0 { ingredientIDs.insert(key.value) }
                if key.namespace == "time" { timeBucket = key.value }
            }
            let positiveCooks = history.cooks.filter {
                ($0.rating.map { $0.value >= 4 } ?? false) || $0.wouldMakeAgain == true
            }
            func bump(
                _ key: String, _ positive: Bool, _ last: Instant,
                _ counts: inout [String: (positive: Int, total: Int, last: Instant?)]
            ) {
                var entry = counts[key] ?? (0, 0, nil)
                entry.total += 1
                if positive { entry.positive += 1 }
                if entry.last == nil || last > entry.last! { entry.last = last }
                counts[key] = entry
            }
            for cook in history.cooks {
                let positive = positiveCooks.contains { $0.at == cook.at }
                for ingredient in ingredientIDs {
                    bump(ingredient, positive, cook.at, &cookCounts)
                }
                if let bucket = timeBucket {
                    bump(bucket, positive, cook.at, &timeCounts)
                }
            }
            for substitution in history.substitutions where substitution.to == nil {
                let ingredient = substitution.from.rawValue
                var entry = removeCounts[ingredient] ?? (0, 0, nil)
                entry.positive += 1
                if entry.last == nil || substitution.at > entry.last! { entry.last = substitution.at }
                removeCounts[ingredient] = entry
            }
        }

        let source = "eater \(eaterID.rawValue)"
        // One sentence per ingredient: an avoid (removals) wins over a like
        // when both fire; any stated pin on the feature suppresses both —
        // the stated sentence replaces the inference (SPEC 3.3: explicit
        // beats learned).
        let ingredients = Set(cookCounts.keys).union(removeCounts.keys).sorted()
        for ingredient in ingredients {
            let cookEntry = cookCounts[ingredient] ?? (0, 0, nil)
            let removal = removeCounts[ingredient]
            let feature = FeatureKey(namespace: "ingredient", value: ingredient)
            let pinned =
                householdStated[feature] != nil
                || eater.explicit.stated[feature] != nil
            guard !pinned, cookEntry.total >= 3 else { continue }
            let name = displayName(ingredient)
            if let removal,
                Double(removal.positive) / Double(cookEntry.total) >= 0.6,
                liveness(removal.last, halfLife: config.substitutionEvidenceHalfLifeDays, now: now)
            {
                sentences.append(
                    ProfileSentence(
                        id: "learned.avoid.ingredient.\(ingredient)",
                        text:
                            "You avoid \(name): you removed it \(removal.positive) of the \(cookEntry.total) times it was in a recipe you cooked, most recently \(recencyCore(removal.last!, now: now)).",
                        provenance: .learned, feature: feature, ingredient: IngredientID(ingredient),
                        evidence: Evidence(
                            numerator: removal.positive, denominator: cookEntry.total,
                            lastSeen: removal.last, note: source),
                        edits: .init(
                            thisIsWrong: .setPreference(feature: feature, polarity: .like),
                            dontAskAgain: neverSuggestOp(ingredient),
                            reopen: nil)))
            } else if Double(cookEntry.positive) / Double(cookEntry.total) >= 0.6,
                liveness(cookEntry.last, halfLife: config.cookedEvidenceHalfLifeDays, now: now)
            {
                sentences.append(
                    ProfileSentence(
                        id: "learned.like.ingredient.\(ingredient)",
                        text:
                            "You lean toward \(name): \(cookEntry.positive) of the \(cookEntry.total) \(name) recipes you cooked landed well, most recently \(recencyCore(cookEntry.last!, now: now)).",
                        provenance: .learned, feature: feature, ingredient: IngredientID(ingredient),
                        evidence: Evidence(
                            numerator: cookEntry.positive, denominator: cookEntry.total,
                            lastSeen: cookEntry.last, note: source),
                        edits: .init(
                            thisIsWrong: .setPreference(feature: feature, polarity: .dislike),
                            dontAskAgain: neverSuggestOp(ingredient),
                            reopen: nil)))
            }
        }

        for (bucket, counts) in timeCounts.sorted(by: { $0.key < $1.key }) {
            guard counts.total >= 3,
                Double(counts.positive) / Double(counts.total) >= 0.6,
                liveness(counts.last, halfLife: config.cookedEvidenceHalfLifeDays, now: now)
            else { continue }
            let feature = FeatureKey(namespace: "time", value: bucket)
            sentences.append(
                ProfileSentence(
                    id: "learned.lean.time.\(bucket)",
                    text:
                        "You lean toward \(timePhrase(bucket)): \(counts.positive) of the \(counts.total) recipes you cooked and enjoyed were \(timePhrase(bucket)), most recently \(recencyCore(counts.last!, now: now)).",
                    provenance: .learned, feature: feature, ingredient: nil,
                    evidence: Evidence(
                        numerator: counts.positive, denominator: counts.total, lastSeen: counts.last,
                        note: source),
                    edits: .init(
                        thisIsWrong: .setPreference(feature: feature, polarity: .dislike),
                        dontAskAgain: nil, reopen: nil)))
        }
        return sentences.sorted { $0.id < $1.id }
    }

    private static func neverSuggestOp(_ raw: String) -> ProfileEditOp? {
        IngredientID(raw).map { .setNeverSuggest(ingredient: $0) }
    }

    /// Evidence is alive while its newest event is still within three
    /// half-lives (decay >= 1/8). Weak inferences expire (SPEC 3.3).
    private static func liveness(_ last: Instant?, halfLife: Double, now: Instant) -> Bool {
        guard let last else { return false }
        let age = Double(last.days(to: now))
        guard age >= 0 else { return false }
        return Foundation.pow(0.5, age / max(halfLife, 1)) >= 1.0 / 8.0
    }

    private static func recency(_ at: Instant, now: Instant) -> String {
        recencyCore(at, now: now)
    }

    private static func recencyCore(_ at: Instant, now: Instant) -> String {
        let days = at.days(to: now)
        switch days {
        case ..<0: return "pending"
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    private static func timePhrase(_ bucket: String) -> String {
        switch bucket {
        case "le15": return "quick meals"
        case "le30": return "weeknight meals"
        case "le60": return "hour-long meals"
        default: return "long, slow meals"
        }
    }

    /// Ingredient ids are snake_case; sentences read them as words. The raw
    /// id stays available on the sentence for exact matching.
    private static func displayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }
}
