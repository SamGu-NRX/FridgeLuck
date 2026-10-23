import Foundation

/// One finding from the strict canon linter, in the `data/food-safety/README.md`
/// finding format: the unsafe text the user reads, the reviewed rule it violates
/// (with its verbatim source quote), and one exact rewrite that fixes it.
///
/// The strict contract (README clauses 1–7) needs finding kinds the legacy
/// `LintFlag.Kind` set cannot express — below-minimum temperatures, thermometer
/// wording missing, rest time missing, oven temperatures posing as doneness,
/// metadata not shown in the text, review flags, and fail-closed. `LintFlag`
/// and its six kinds stay untouched because `BundledRecipeAudit` switches over
/// them exhaustively; `LintFinding` carries every kind, legacy and strict, and
/// is the API the canon contract is pinned against.
public struct LintFinding: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        // Legacy classes. Raw values mirror `LintFlag.Kind` exactly.
        case appearanceDoneness
        case timeOnlyCooking
        case rawEggNoWarning
        case ambientThawing
        case leftoversHeldOut
        case reheatingWithoutThermometer

        // Strict canon classes (contract clauses 1–7).
        /// Clause 2: an internal temperature is stated but below the class minimum.
        case belowMinimumTemperature
        /// Clause 1: an internal temperature at or above the minimum is stated, but no thermometer is named.
        case missingThermometer
        /// Clause 2: no internal temperature is stated at all (the umbrella case).
        case missingInternalTemperature
        /// Clause 3: the class requires a rest time the text does not state (or states too short).
        case missingRestTime
        /// Clause 4: an oven/pan/microwave temperature stands where doneness is claimed.
        case ovenTemperatureAsDoneness
        /// Clause 5: the record's structured safety field never appears in the instruction text.
        case metadataNotInText
        /// Clause 6: the protein matches no doneness class — a reviewer must decide, never a pass.
        case flagForReview
        /// Clause 7: missing/unparseable rules data, unparseable record, unknown class.
        case failClosed
    }

    /// The finding kind.
    public let kind: Kind
    /// The `rules.json` rule id the finding enforces (empty for review flags and
    /// fail-closed findings, where no reviewed rule exists to cite).
    public let ruleID: String
    /// The matched phrase (empty for context-level findings).
    public let phrase: String
    /// "ORG — Title" of the primary source (empty when no rule applies).
    public let sourceAttribution: String
    public let sourceURL: String
    /// A verbatim quote from the primary source supporting the finding.
    public let sourceQuote: String
    /// The class minimum (°F) the rewrite points at, when the finding carries a
    /// temperature requirement.
    public let suggestedTempF: Double?
    /// The full proposed replacement text for the step (the exact rewrite).
    public let suggestedRewrite: String
    /// What is missing, what the reviewer must decide, or why the linter failed
    /// closed. Findings never guess: review and fail-closed findings carry the
    /// open question here.
    public let detail: String
    /// The verbatim step text the finding was raised against.
    public let currentText: String

    // Finding-format anchors, attached by record-aware callers (the linter
    // itself does not know the file, record id or field a step came from).
    public var filePath: String?
    public var recordID: String?
    public var field: String?

    public init(kind: Kind, ruleID: String, phrase: String,
                sourceAttribution: String, sourceURL: String, sourceQuote: String,
                suggestedTempF: Double? = nil, suggestedRewrite: String = "",
                detail: String = "", currentText: String = "",
                filePath: String? = nil, recordID: String? = nil, field: String? = nil) {
        self.kind = kind
        self.ruleID = ruleID
        self.phrase = phrase
        self.sourceAttribution = sourceAttribution
        self.sourceURL = sourceURL
        self.sourceQuote = sourceQuote
        self.suggestedTempF = suggestedTempF
        self.suggestedRewrite = suggestedRewrite
        self.detail = detail
        self.currentText = currentText
        self.filePath = filePath
        self.recordID = recordID
        self.field = field
    }

    /// Lifts a legacy `LintFlag` into the strict finding format unchanged.
    public init(from flag: LintFlag, currentText: String = "",
                filePath: String? = nil, recordID: String? = nil, field: String? = nil) {
        self.init(
            kind: Self.convert(flag.kind),
            ruleID: flag.ruleID,
            phrase: flag.phrase,
            sourceAttribution: flag.sourceAttribution,
            sourceURL: flag.sourceURL,
            sourceQuote: flag.sourceQuote,
            suggestedTempF: flag.suggestedTempF,
            suggestedRewrite: flag.suggestedRewrite,
            currentText: currentText,
            filePath: filePath, recordID: recordID, field: field
        )
    }

    private static func convert(_ legacy: LintFlag.Kind) -> Kind {
        switch legacy {
        case .appearanceDoneness: return .appearanceDoneness
        case .timeOnlyCooking: return .timeOnlyCooking
        case .rawEggNoWarning: return .rawEggNoWarning
        case .ambientThawing: return .ambientThawing
        case .leftoversHeldOut: return .leftoversHeldOut
        case .reheatingWithoutThermometer: return .reheatingWithoutThermometer
        }
    }

    /// Deterministic report order: the strict canon kinds first (clauses 1–7),
    /// then the legacy classes in their historical order.
    static let reportOrder: [Kind] = [
        .failClosed, .belowMinimumTemperature, .missingThermometer,
        .missingInternalTemperature, .missingRestTime, .ovenTemperatureAsDoneness,
        .metadataNotInText, .flagForReview,
        .appearanceDoneness, .timeOnlyCooking, .rawEggNoWarning,
        .ambientThawing, .leftoversHeldOut, .reheatingWithoutThermometer,
    ]

    /// The finding as one canon-format line:
    /// `file · record id · field · current text (verbatim snippet) · required change (exact rewrite + rule id + citation)`.
    /// "Flag for review" findings state what the reviewer must decide instead of
    /// guessing a rule; fail-closed findings state what is missing.
    public func findingLine(file: String?, recordID: String?, field: String?) -> String {
        let anchor = [file, recordID, field].compactMap { $0 }.joined(separator: " · ")
        var parts: [String] = []
        if !anchor.isEmpty { parts.append(anchor) }
        if !currentText.isEmpty { parts.append("current text: “\(currentText)”") }
        if !phrase.isEmpty { parts.append("matched phrase: “\(phrase)”") }
        switch kind {
        case .flagForReview:
            parts.append("FLAG FOR REVIEW — \(detail)")
        case .failClosed:
            parts.append("FAIL CLOSED — \(detail)")
        default:
            if !detail.isEmpty { parts.append(detail) }
            if !suggestedRewrite.isEmpty { parts.append("required change: \(suggestedRewrite)") }
            if !ruleID.isEmpty { parts.append("rule `\(ruleID)`") }
            if !sourceAttribution.isEmpty {
                parts.append("source: \(sourceAttribution), \(sourceURL): “\(sourceQuote)”")
            }
        }
        return "[\(kind.rawValue)] " + parts.joined(separator: " · ")
    }
}
