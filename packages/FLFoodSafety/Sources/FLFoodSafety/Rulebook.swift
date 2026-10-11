import Foundation

// MARK: - Food classes (the RS FSIS class names from evaluation/suites/recipes/rs.py)

/// The eight FSIS food classes the suite C corpus linter (`rs.py`) checks, with
/// the safe minimum internal temperature each must reach. `rules.json` uses
/// exactly these names so corpus safety fields can cite the rulebook directly.
public enum FoodClass: String, CaseIterable, Decodable, Sendable {
    case meatPoultry = "meat_poultry"
    case meatGround = "meat_ground"
    case meatWholeCutPork = "meat_whole_cut_pork"
    case meatWholeCutRed = "meat_whole_cut_red"
    case fleshFish = "flesh_fish"
    case fleshShellfish = "flesh_shellfish"
    case egg = "egg"
    case leftovers = "leftovers"

    /// Safe minimum internal temperature in °F, as published by the USDA FSIS
    /// safe minimum internal temperature chart and mirrored in `rs.py`.
    public var minimumTempF: Double {
        switch self {
        case .meatPoultry: return 165
        case .meatGround: return 160
        case .meatWholeCutPork: return 145
        case .meatWholeCutRed: return 145
        case .fleshFish: return 145
        case .fleshShellfish: return 145
        case .egg: return 160
        case .leftovers: return 165
        }
    }
}

// MARK: - Topics

public enum RuleTopic: String, CaseIterable, Decodable, Sendable {
    case doneness
    case reheating
    case coolingWindow = "cooling_window"
    case dangerZone = "danger_zone"
    case leftoverStorageWindow = "leftover_storage_window"
    case coolingMethod = "cooling_method"
    case thawing
    case crossContamination = "cross_contamination"
    case hygiene
    case rawEgg = "raw_egg"
    case restTime = "rest_time"
    case thermometer
    case appearanceNotSufficient = "appearance_not_sufficient"
    case highRiskGroups = "high_risk_groups"
}

public enum CheckKind: String, CaseIterable, Decodable, Sendable {
    case thermometer
    case rest
}

// MARK: - Model

/// One verbatim quotation from a primary public source. `quotes` collects every
/// `quote`-family key (`quote`, `second_quote` … `tenth_quote`, `table_quote`)
/// from the JSON so additional verbatim quotes can be added without schema churn.
public struct Citation: Equatable, Decodable, Sendable {
    public let id: String
    public let org: String
    public let title: String
    public let url: String
    public let retrieved: String
    public let pageLastUpdated: String?
    public let quotes: [String]

    enum CodingKeys: String, CodingKey, Hashable {
        case id, org, title, url, retrieved
        case pageLastUpdated = "page_last_updated"
        case quote, secondQuote = "second_quote", thirdQuote = "third_quote"
        case fourthQuote = "fourth_quote", fifthQuote = "fifth_quote"
        case sixthQuote = "sixth_quote", seventhQuote = "seventh_quote"
        case eighthQuote = "eighth_quote", ninthQuote = "ninth_quote"
        case tenthQuote = "tenth_quote", tableQuote = "table_quote"
    }

    private static let quoteKeys: Set<CodingKeys> = [
        .quote, .secondQuote, .thirdQuote, .fourthQuote, .fifthQuote,
        .sixthQuote, .seventhQuote, .eighthQuote, .ninthQuote, .tenthQuote,
        .tableQuote,
    ]

    /// Quote keys in declared JSON order. Quotes are collected in this order,
    /// never container-iteration order: the keyed container's `allKeys` order
    /// varies between processes (hash-seeded storage), which would permute
    /// `quotes` and make rendered reports non-reproducible.
    private static let quoteOrder: [CodingKeys] = [
        .quote, .secondQuote, .thirdQuote, .fourthQuote, .fifthQuote,
        .sixthQuote, .seventhQuote, .eighthQuote, .ninthQuote, .tenthQuote,
        .tableQuote,
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        org = try c.decode(String.self, forKey: .org)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        retrieved = try c.decode(String.self, forKey: .retrieved)
        pageLastUpdated = try c.decodeIfPresent(String.self, forKey: .pageLastUpdated)

        var quotes: [String] = []
        for key in Self.quoteOrder {
            if let quote = try c.decodeIfPresent(String.self, forKey: key) {
                quotes.append(quote)
            }
        }
        // Unknown keys cannot be addressed by a typed container (they surface
        // only through the raw-JSON pre-flight in `Rulebook.decode`); this
        // loop is belt-and-braces for runtimes whose container does report
        // them.
        let knownFieldKeys: Set<CodingKeys> = [.id, .org, .title, .url, .retrieved, .pageLastUpdated]
        for key in c.allKeys where !knownFieldKeys.contains(key) && !Self.quoteKeys.contains(key) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "Citation has unknown key \(key.stringValue)"
            )
        }
        self.quotes = quotes
    }

    public init(id: String, org: String, title: String, url: String,
                retrieved: String, pageLastUpdated: String? = nil, quotes: [String]) {
        self.id = id
        self.org = org
        self.title = title
        self.url = url
        self.retrieved = retrieved
        self.pageLastUpdated = pageLastUpdated
        self.quotes = quotes
    }

    /// One-line attribution used in flags and rewrites:
    /// "USDA FSIS — Safe Minimum Internal Temperature Chart".
    public var attribution: String { "\(org) — \(title)" }
}

/// A thermometer or rest check. Thermometer checks carry the safe minimum in
/// both °F and °C, thermometer placement, and the rest time (0 when none).
public struct DonenessCheck: Equatable, Decodable, Sendable {
    public let kind: CheckKind
    public let tempF: Double
    public let tempC: Double
    public let restMinutes: Double
    public let placement: String?
    public let alternativeTempF: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case tempF = "temp_f"
        case tempC = "temp_c"
        case restMinutes = "rest_minutes"
        case placement
        case alternativeTempF = "alternative_temp_f"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(CheckKind.self, forKey: .kind)
        tempF = try c.decode(Double.self, forKey: .tempF)
        tempC = try c.decode(Double.self, forKey: .tempC)
        restMinutes = try c.decode(Double.self, forKey: .restMinutes)
        placement = try c.decodeIfPresent(String.self, forKey: .placement)
        alternativeTempF = try c.decodeIfPresent(Double.self, forKey: .alternativeTempF)
    }
}

// MARK: - Strict key checking (pre-flight)

/// The typed decoder cannot see JSON keys that have no `CodingKeys` case —
/// they are dropped before `allKeys` is populated, so a typo'd or surprise
/// key would pass silently. `Rulebook.decode` therefore checks every
/// object's keys against the schema here, on the raw JSON, and fails loudly.
private enum StrictKeys {
    static let topLevel: Set<String> = [
        "schema_version", "retrieved", "name", "rs_alignment",
        "description", "citations", "rules",
    ]
    static let rsAlignment: Set<String> = [
        "consumer", "food_class_names", "minimums_f", "corpus_safety_field",
        "forbidden_phrases", "citation_for_source",
    ]
    static let citation: Set<String> = [
        "id", "org", "title", "url", "retrieved", "page_last_updated",
        "quote", "second_quote", "third_quote", "fourth_quote", "fifth_quote",
        "sixth_quote", "seventh_quote", "eighth_quote", "ninth_quote",
        "tenth_quote", "table_quote",
    ]
    static let rule: Set<String> = [
        "id", "topic", "food_class", "summary", "check", "match_keywords",
        "visual_cues_insufficient", "high_risk_groups", "rs_note",
        "published_appearance_alternative_note", "citation_ids",
    ]
    static let check: Set<String> = [
        "kind", "temp_f", "temp_c", "rest_minutes", "placement", "alternative_temp_f",
    ]

    static func issues(in data: Data) -> [String] {
        var issues: [String] = []
        // Malformed JSON surfaces as a DecodingError from the typed decoder;
        // this pass only adds unknown-key findings when the structure parses.
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return issues
        }
        for key in top.keys where !topLevel.contains(key) {
            issues.append("top level has unknown key '\(key)'")
        }
        if let alignment = top["rs_alignment"] as? [String: Any] {
            for key in alignment.keys where !rsAlignment.contains(key) {
                issues.append("rs_alignment has unknown key '\(key)'")
            }
        }
        let citations = top["citations"] as? [[String: Any]] ?? []
        for (index, citation) in citations.enumerated() {
            for key in citation.keys where !Self.citation.contains(key) {
                issues.append("citations[\(index)] has unknown key '\(key)'")
            }
        }
        let rules = top["rules"] as? [[String: Any]] ?? []
        for (index, rule) in rules.enumerated() {
            let ruleID = rule["id"] as? String ?? "?"
            for key in rule.keys where !Self.rule.contains(key) {
                issues.append("rules[\(index)] '\(ruleID)' has unknown key '\(key)'")
            }
            if let check = rule["check"] as? [String: Any] {
                for key in check.keys where !Self.check.contains(key) {
                    issues.append("rules[\(index)] '\(ruleID)' check has unknown key '\(key)'")
                }
            }
        }
        return issues
    }
}

public struct Rule: Equatable, Decodable, Sendable {
    public let id: String
    public let topic: RuleTopic
    public let foodClass: FoodClass?
    public let summary: String
    public let check: DonenessCheck?
    public let matchKeywords: [String]?
    public let visualCuesInsufficient: [String]?
    public let highRiskGroups: [String]?
    public let rsNote: String?
    public let publishedAppearanceAlternativeNote: String?
    public let citationIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, topic
        case foodClass = "food_class"
        case summary, check
        case matchKeywords = "match_keywords"
        case visualCuesInsufficient = "visual_cues_insufficient"
        case highRiskGroups = "high_risk_groups"
        case rsNote = "rs_note"
        case publishedAppearanceAlternativeNote = "published_appearance_alternative_note"
        case citationIDs = "citation_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        topic = try c.decode(RuleTopic.self, forKey: .topic)
        foodClass = try c.decodeIfPresent(FoodClass.self, forKey: .foodClass)
        summary = try c.decode(String.self, forKey: .summary)
        check = try c.decodeIfPresent(DonenessCheck.self, forKey: .check)
        matchKeywords = try c.decodeIfPresent([String].self, forKey: .matchKeywords)
        visualCuesInsufficient = try c.decodeIfPresent([String].self, forKey: .visualCuesInsufficient)
        highRiskGroups = try c.decodeIfPresent([String].self, forKey: .highRiskGroups)
        rsNote = try c.decodeIfPresent(String.self, forKey: .rsNote)
        publishedAppearanceAlternativeNote = try c.decodeIfPresent(String.self, forKey: .publishedAppearanceAlternativeNote)
        citationIDs = try c.decode([String].self, forKey: .citationIDs)
    }
}

/// The suite C alignment block, carried through so consumers can see the
/// contract this rulebook honours (`rs.py` class names, minimums, and the
/// corpus safety-field shape).
public struct RSAlignment: Equatable, Decodable, Sendable {
    public let consumer: String
    public let foodClassNames: String
    public let minimumsF: [String: Double]
    public let corpusSafetyField: String
    public let forbiddenPhrases: String
    public let citationForSource: String

    enum CodingKeys: String, CodingKey {
        case consumer
        case foodClassNames = "food_class_names"
        case minimumsF = "minimums_f"
        case corpusSafetyField = "corpus_safety_field"
        case forbiddenPhrases = "forbidden_phrases"
        case citationForSource = "citation_for_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consumer = try c.decode(String.self, forKey: .consumer)
        foodClassNames = try c.decode(String.self, forKey: .foodClassNames)
        minimumsF = try c.decode([String: Double].self, forKey: .minimumsF)
        corpusSafetyField = try c.decode(String.self, forKey: .corpusSafetyField)
        forbiddenPhrases = try c.decode(String.self, forKey: .forbiddenPhrases)
        citationForSource = try c.decode(String.self, forKey: .citationForSource)
    }
}

// MARK: - Rulebook

/// The decoded reviewed rulebook. `Rulebook.decode` fails loudly: unknown keys,
/// unknown topics/classes, missing citations and internal inconsistencies all
/// throw before the rulebook can be used.
public struct Rulebook: Equatable, Decodable, Sendable {
    public let schemaVersion: Int
    public let retrieved: String
    public let name: String
    public let rsAlignment: RSAlignment
    public let descriptionText: String
    public let citations: [Citation]
    public let rules: [Rule]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case retrieved, name
        case rsAlignment = "rs_alignment"
        case description
        case citations, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        retrieved = try c.decode(String.self, forKey: .retrieved)
        name = try c.decode(String.self, forKey: .name)
        rsAlignment = try c.decode(RSAlignment.self, forKey: .rsAlignment)
        descriptionText = try c.decode(String.self, forKey: .description)
        citations = try c.decode([Citation].self, forKey: .citations)
        rules = try c.decode([Rule].self, forKey: .rules)
    }

    public func citation(id: String) -> Citation? {
        citations.first { $0.id == id }
    }

    public func citations(for rule: Rule) -> [Citation] {
        rule.citationIDs.compactMap { citation(id: $0) }
    }

    /// Decodes and validates. Throws `RulebookError` listing every schema
    /// violation — the failure is loud, nothing half-valid ships.
    public static func decode(_ data: Data) throws -> Rulebook {
        let keyIssues = StrictKeys.issues(in: data)
        guard keyIssues.isEmpty else { throw RulebookError(issues: keyIssues) }
        let book = try JSONDecoder().decode(Rulebook.self, from: data)
        let issues = book.validate()
        guard issues.isEmpty else { throw RulebookError(issues: issues) }
        return book
    }

    public static func decode(_ json: String) throws -> Rulebook {
        try decode(Data(json.utf8))
    }
}

public struct RulebookError: Error, CustomStringConvertible {
    public let issues: [String]
    public var description: String {
        "Rulebook schema violation (\(issues.count)):\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Validation

extension Rulebook {
    /// Post-decode semantic checks. Enforced by tests against the shipped
    /// rules.json and against mutated fixtures (a rule with no source fails).
    public func validate() -> [String] {
        var issues: [String] = []
        if schemaVersion != 1 { issues.append("schema_version must be 1, got \(schemaVersion)") }
        issues.append(contentsOf: isoDateIssues(retrieved, field: "retrieved"))

        var citationByID: [String: Citation] = [:]
        for citation in citations {
            if citationByID[citation.id] != nil {
                issues.append("duplicate citation id \(citation.id)")
            }
            citationByID[citation.id] = citation
            let where_ = "citation \(citation.id)"
            if citation.org.isEmpty { issues.append("\(where_): org is empty") }
            if citation.title.isEmpty { issues.append("\(where_): title is empty") }
            if !(citation.url.hasPrefix("http://") || citation.url.hasPrefix("https://")) {
                issues.append("\(where_): url is not absolute http(s): \(citation.url)")
            }
            issues.append(contentsOf: isoDateIssues(citation.retrieved, field: "\(where_) retrieved"))
            if citation.quotes.isEmpty {
                issues.append("\(where_): has no verbatim quote")
            }
            for (i, quote) in citation.quotes.enumerated() where quote.count < 20 {
                issues.append("\(where_): quote[\(i)] is not a verbatim quotation (too short)")
            }
        }

        var ruleIDs = Set<String>()
        for rule in rules {
            if !ruleIDs.insert(rule.id).inserted {
                issues.append("duplicate rule id \(rule.id)")
            }
            let where_ = "rule \(rule.id)"
            if rule.citationIDs.isEmpty {
                issues.append("\(where_): no citation — a rule without a source does not ship")
            }
            for id in rule.citationIDs where citationByID[id] == nil {
                issues.append("\(where_): citation id \(id) does not resolve")
            }
            if let check = rule.check {
                if check.tempF < 90 || check.tempF > 300 {
                    issues.append("\(where_): check temp_f \(check.tempF) outside the plausible range")
                }
                let converted = (check.tempF - 32) * 5 / 9
                if abs(check.tempC - converted) > 1.0 {
                    issues.append("\(where_): check temp_c \(check.tempC) does not match temp_f \(check.tempF)")
                }
                if check.restMinutes < 0 { issues.append("\(where_): rest_minutes is negative") }
            }
            if rule.topic == .doneness && rule.check == nil {
                issues.append("\(where_): doneness rule has no thermometer check")
            }
            if let keywords = rule.matchKeywords, keywords.isEmpty {
                issues.append("\(where_): match_keywords is empty")
            }
        }
        return issues
    }

    private func isoDateIssues(_ value: String, field: String) -> [String] {
        guard value.count == 10, value.dropFirst(4).first == "-", value.dropLast(6).suffix(1) != "-" else {
            return ["\(field): '\(value)' is not an ISO date (YYYY-MM-DD)"]
        }
        return []
    }
}
