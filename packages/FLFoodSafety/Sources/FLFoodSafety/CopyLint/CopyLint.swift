import Foundation

/// One record of user-facing copy for `CopyLint` to scan: a recipe step, a
/// use-it-up tip, a LeChef line or a UI string. The linter is source-agnostic —
/// the caller decides which records to pass and where they came from; the
/// `file`/`recordID`/`field` triple reports the finding's location in the
/// canon format.
public struct CopyRecord: Equatable, Sendable {
    /// File the record came from (for example `recipes.json`).
    public var file: String
    /// The record's own id inside that file.
    public var recordID: String
    /// The field the text is a value of (for example `step`, `tip`, `lechef`).
    public var field: String
    /// The verbatim copy to scan.
    public var text: String

    public init(file: String, recordID: String, field: String, text: String) {
        self.file = file
        self.recordID = recordID
        self.field = field
        self.text = text
    }
}

/// One copy-lint finding, in the canon format: file · record id · field ·
/// current text (verbatim snippet) · required change (exact rewrite plus the
/// policy citation that motivates it).
public struct CopyFinding: Equatable, Sendable {
    public let file: String
    public let recordID: String
    public let field: String
    /// The `CopyLint` pattern id (for example `smell-safety-test`), which is
    /// the banned-pattern row in `COPY.md`'s "What never to say" table.
    public let patternID: String
    /// A verbatim snippet of the flagged copy: the sentence containing the
    /// first matched phrase, exactly as it appears in the record.
    public let currentText: String
    /// The exact replacement copy, followed by the policy citation.
    public let requiredChange: String
    /// The whole finding on one line: file · record id · field · current text
    /// · required change.
    public let canonicalLine: String

    public init(file: String, recordID: String, field: String, patternID: String,
                currentText: String, requiredChange: String) {
        self.file = file
        self.recordID = recordID
        self.field = field
        self.patternID = patternID
        self.currentText = currentText
        self.requiredChange = requiredChange
        self.canonicalLine = [file, recordID, field, currentText, requiredChange]
            .joined(separator: " · ")
    }
}

/// Decoding or validation failure. Every message says what is missing or
/// invalid so the pattern file can be fixed, not guessed at (fail closed).
public enum CopyLintError: Error, LocalizedError, Equatable {
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let reason):
            return "copy-lint pattern data is invalid: \(reason)"
        }
    }
}

/// Flags spoilage and use-it-up phrasing that the food-safety canon bans, and
/// proposes cited replacement copy.
///
/// The linter is self-contained: it decodes its own pattern data
/// (`data/food-safety/copy-lint-patterns.json`) and has no dependency on the
/// rulebook, doneness types or any other part of the package. The policy it
/// enforces is `data/food-safety/COPY.md`, section "Spoilage and use-it-up
/// policy"; when that section and this linter disagree, fix one of them in the
/// same commit.
///
/// Matching model: a pattern fires on a record when every group in its `all`
/// list matches somewhere in the record text (case-insensitive) and no `except`
/// regex matches the record. Groups model the ingredients of the banned claim
/// (a spoilage descriptor, a use-or-salvage action, a raw-fish safety claim…);
/// `except` carries precision guards only — discard instructions, "before it
/// turns" quality phrasing, intentionally sprouted ingredient names,
/// previously-frozen and thermometer mitigations — never a salvage permission.
/// One finding per pattern per record; the snippet is the sentence containing
/// the first matched phrase. The lint is a heuristic net for review, not a
/// parser: a record that mixes banned salvage with discard guidance in
/// different sentences can under-flag or over-flag, so findings are reviewed by
/// a human, and the pinned true negatives in `CopyLintTests` define what clean
/// copy looks like.
///
/// Decoding is strict and fails closed: unknown keys, an invalid regex, an
/// empty pattern set, a missing citation field, a short quote, a non-https URL
/// or a malformed retrieval date all throw instead of silently narrowing the
/// policy — the finding says what is missing.
public struct CopyLint: Sendable {
    private struct DecodedPattern {
        var id: String
        var all: [[String]]
        var except: [String]
        var rewrite: String
        var citationOrg: String
        var citationTitle: String
        var citationURL: String
        var citationRetrieved: String
        var citationQuote: String
    }

    /// A pattern with its regexes compiled. `NSRegularExpression` is documented
    /// thread-safe for matching, so the compiled array is safe to reuse.
    private struct CompiledPattern {
        var pattern: DecodedPattern
        var all: [[NSRegularExpression]]
        var except: [NSRegularExpression]

        init(_ pattern: DecodedPattern) throws {
            self.pattern = pattern
            self.all = try pattern.all.map(CopyLint.compile)
            self.except = try CopyLint.compile(pattern.except)
        }
    }

    private let patterns: [CompiledPattern]

    /// The pattern ids, in file order — the banned-pattern rows of `COPY.md`.
    public var patternIDs: [String] { patterns.map { $0.pattern.id } }

    /// Decodes and validates pattern data. Throws `CopyLintError` on any
    /// missing or invalid piece — the linter never runs with a narrowed policy.
    public init(patternsData: Data) throws {
        self.patterns = try CopyLint.decode(patternsData: patternsData).map(CompiledPattern.init)
    }

    /// Scans the records and returns one finding per (record, pattern) hit, in
    /// record order then pattern order.
    public func lint(_ records: [CopyRecord]) -> [CopyFinding] {
        var findings: [CopyFinding] = []
        for record in records {
            for compiled in patterns {
                guard let snippet = Self.firstSnippet(record: record, compiled: compiled) else { continue }
                findings.append(CopyFinding(
                    file: record.file,
                    recordID: record.recordID,
                    field: record.field,
                    patternID: compiled.pattern.id,
                    currentText: snippet,
                    requiredChange: Self.requiredChange(pattern: compiled.pattern)
                ))
            }
        }
        return findings
    }

    // MARK: Pattern application

    /// The snippet covering the matched claim, or nil when the pattern does
    /// not fire (a group missed, or an except guard matched).
    ///
    /// Groups may match in different sentences ("Buy spinach. If it's already
    /// slimy, blend it in."), so the snippet spans from the sentence holding
    /// the earliest group match to the sentence holding the latest one —
    /// verbatim text, both terminators kept.
    private static func firstSnippet(record: CopyRecord, compiled: CompiledPattern) -> String? {
        let nsText = record.text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        // Every group must match somewhere; keep the span across the earliest
        // and latest per-group matches for the snippet.
        var spanStart = Int.max
        var spanEnd = 0
        for group in compiled.all {
            var groupMatched = false
            for regex in group {
                guard let match = regex.firstMatch(in: record.text, options: [], range: full),
                      match.range.location != NSNotFound else { continue }
                groupMatched = true
                spanStart = min(spanStart, match.range.location)
                spanEnd = max(spanEnd, match.range.location + match.range.length)
            }
            guard groupMatched else { return nil }
        }

        for guardRegex in compiled.except {
            if guardRegex.firstMatch(in: record.text, options: [], range: full) != nil {
                return nil
            }
        }

        return snippet(coveringFrom: spanStart, to: spanEnd, in: nsText)
    }

    private static func compile(_ patterns: [String]) throws -> [NSRegularExpression] {
        try patterns.map { pattern in
            do {
                return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                throw CopyLintError.validationFailed("invalid regex \(pattern): \(error)")
            }
        }
    }

    /// The verbatim text from the start of the sentence holding `from` to the
    /// end of the sentence holding `to` (sentence bounds are `.`, `!`, `?` or
    /// a newline; terminators are kept), trimmed of surrounding whitespace.
    private static func snippet(coveringFrom from: Int, to: Int, in nsText: NSString) -> String {
        // ASCII codes of the sentence terminators: '.', '!', '?', newline.
        let terminators: Set<unichar> = [46, 33, 63, 10]

        var start = 0
        var i = min(from, nsText.length) - 1
        while i >= 0 {
            if terminators.contains(nsText.character(at: i)) {
                start = i + 1
                break
            }
            i -= 1
        }

        var end = min(max(from, to), nsText.length)
        while end < nsText.length {
            if terminators.contains(nsText.character(at: end)) {
                end += 1 // keep the terminator — the snippet stays verbatim
                break
            }
            end += 1
        }

        let clampedStart = min(start, nsText.length)
        let range = NSRange(location: clampedStart, length: max(0, end - clampedStart))
        return nsText.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The required change: the exact replacement copy plus the policy
    /// citation (org, title, URL, retrieval date, verbatim quote).
    private static func requiredChange(pattern: DecodedPattern) -> String {
        "Replace with: \(pattern.rewrite) (policy: \(pattern.id); source: \(pattern.citationOrg) — \(pattern.citationTitle); \(pattern.citationURL); retrieved \(pattern.citationRetrieved): \"\(pattern.citationQuote)\")"
    }

    // MARK: Strict decode (fail closed)

    private static func decode(patternsData: Data) throws -> [DecodedPattern] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: patternsData)
        } catch {
            throw CopyLintError.validationFailed("pattern data is not valid JSON: \(error)")
        }
        guard let doc = raw as? [String: Any] else {
            throw CopyLintError.validationFailed("top level must be an object")
        }

        return try decodeDocument(doc)
    }

    private static func decodeDocument(_ doc: [String: Any]) throws -> [DecodedPattern] {
        try checkKeys(doc, allowed: ["schema_version", "name", "retrieved", "policy_doc", "notes", "patterns"],
                      what: "top level")

        guard doc["schema_version"] as? Int == 1 else {
            throw CopyLintError.validationFailed("schema_version must be 1 (the shipped policy is version 1); found: \(doc["schema_version"] ?? "missing")")
        }
        guard let patterns = doc["patterns"] as? [[String: Any]] else {
            throw CopyLintError.validationFailed("patterns must be an array of objects")
        }
        guard !patterns.isEmpty else {
            throw CopyLintError.validationFailed("patterns must not be empty — an empty set would silently narrow the policy")
        }
        guard let topRetrieved = doc["retrieved"] as? String, !topRetrieved.isEmpty else {
            throw CopyLintError.validationFailed("top-level retrieved is missing or empty")
        }
        try checkDate(topRetrieved, what: "top-level retrieved")

        var decoded: [DecodedPattern] = []
        var seenIDs: Set<String> = []
        for (index, entry) in patterns.enumerated() {
            try checkKeys(entry, allowed: ["id", "all", "except", "rewrite", "citation"], what: "pattern \(index)")

            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw CopyLintError.validationFailed("pattern \(index): id is missing or empty")
            }
            guard !seenIDs.contains(id) else {
                throw CopyLintError.validationFailed("pattern \(index): duplicate id \(id)")
            }
            seenIDs.insert(id)

            guard let all = entry["all"] as? [[Any]], !all.isEmpty, all.count <= 4 else {
                throw CopyLintError.validationFailed("pattern \(id): all must be an array of 1–4 groups")
            }
            var groups: [[String]] = []
            for (groupIndex, group) in all.enumerated() {
                guard let regexes = group as? [String], !regexes.isEmpty, regexes.count <= 12 else {
                    throw CopyLintError.validationFailed("pattern \(id): group \(groupIndex) must be an array of 1–12 regex strings")
                }
                _ = try compile(regexes) // throws on an invalid regex
                groups.append(regexes)
            }

            var except: [String] = []
            if let rawExcept = entry["except"] {
                guard let regexes = rawExcept as? [String], !regexes.isEmpty else {
                    throw CopyLintError.validationFailed("pattern \(id): except must be an array of regex strings when present")
                }
                _ = try compile(regexes)
                except = regexes
            }

            guard let rewrite = entry["rewrite"] as? String, !rewrite.isEmpty else {
                throw CopyLintError.validationFailed("pattern \(id): rewrite is missing or empty — every banned pattern carries its exact replacement copy")
            }

            guard let citation = entry["citation"] as? [String: Any] else {
                throw CopyLintError.validationFailed("pattern \(id): citation is missing")
            }
            try checkKeys(citation, allowed: ["id", "org", "title", "url", "retrieved", "quote"], what: "pattern \(id) citation")
            for field in ["id", "org", "title", "url", "retrieved", "quote"] {
                guard let value = citation[field] as? String, !value.isEmpty else {
                    throw CopyLintError.validationFailed("pattern \(id): citation.\(field) is missing or empty")
                }
            }
            guard let quote = citation["quote"] as? String, quote.count >= 20 else {
                throw CopyLintError.validationFailed("pattern \(id): citation.quote too short to be verbatim")
            }
            guard let url = citation["url"] as? String, url.hasPrefix("https://") else {
                throw CopyLintError.validationFailed("pattern \(id): citation.url must be https")
            }
            try checkDate(citation["retrieved"] as? String ?? "", what: "pattern \(id) citation.retrieved")

            decoded.append(DecodedPattern(
                id: id,
                all: groups,
                except: except,
                rewrite: rewrite,
                citationOrg: citation["org"] as? String ?? "",
                citationTitle: citation["title"] as? String ?? "",
                citationURL: citation["url"] as? String ?? "",
                citationRetrieved: citation["retrieved"] as? String ?? "",
                citationQuote: citation["quote"] as? String ?? ""
            ))
        }
        return decoded
    }

    private static func checkKeys(_ dict: [String: Any], allowed: Set<String>, what: String) throws {
        let unknown = Set(dict.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw CopyLintError.validationFailed("\(what): unknown key(s) \(unknown.sorted().joined(separator: ", ")) — extend the decoder before extending the file")
        }
    }

    private static func checkDate(_ value: String, what: String) throws {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw CopyLintError.validationFailed("\(what): retrieval date must be YYYY-MM-DD, found: \(value)")
        }
    }
}
