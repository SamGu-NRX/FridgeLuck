import Foundation

/// Replay corpus record (`labels.jsonl` line), mirroring the generator's schema.
public struct CorpusRecord: Decodable {
    public struct Source: Decodable {
        public let kind: String
        public let generator: String
        public let reference: String
    }

    public struct FieldEntry: Decodable {
        public let value: String?
        public let unit: String?
        public let basis: String?
        public let observable: Bool
        public let evidence_line: Int?
        public let unobservability_reason: String?
    }

    public let record_id: String
    public let group_id: String
    public let variant: String
    public let family: String
    public let variant_kind: String
    public let source: Source
    public let lines: [String]
    public let corruption: JSONAny?
    public let fields: [String: FieldEntry]
}

/// Type-erased JSON value; only presence/absence of `corruption` matters to the replay.
public struct JSONAny: Decodable {}

public struct ReplayReport: Codable, Equatable {
    public struct VariantReport: Codable, Equatable {
        public var records = 0
        public var keywordPositive = 0
        public var caloriesTotal = 0
        public var caloriesMatched = 0
        public var servingSizeTotal = 0
        public var servingSizeMatched = 0
        public var servingsTotal = 0
        public var servingsMatched = 0
    }

    public struct FamilyReport: Codable, Equatable {
        public var byVariant: [String: VariantReport]
    }

    public var records: Int
    public var groups: Int
    public var families: [String: FamilyReport]
}

/// Runs the production `NutritionLabelParser` over every corpus record and
/// scores its extractions against the corpus truth tables.
public enum CorpusReplay {
    /// Bases whose column represents "what one serving contains", in priority order.
    static let servingBases = ["per_serving", "per_portion"]

    public static func loadCorpus(path: URL) throws -> [CorpusRecord] {
        let data = try Data(contentsOf: path)
        var records: [CorpusRecord] = []
        var decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            records.append(try decoder.decode(CorpusRecord.self, from: Data(line)))
        }
        return records
    }

    public static func run(records: [CorpusRecord]) -> ReplayReport {
        var counts: [String: ReplayReport.VariantReport] = [:]

        for record in records {
            let outcome = NutritionLabelParser.parse(ocrText: record.lines)
            let k = "\(record.family)|\(record.variant_kind)"
            var v = counts[k] ?? ReplayReport.VariantReport()
            v.records += 1
            if outcome.hadNutritionKeywords { v.keywordPositive += 1 }

            if let truth = truthEntry(record, fid: "energy_kcal") {
                v.caloriesTotal += 1
                if let parsed = outcome.parsed?.caloriesPerServing,
                   abs(parsed - (Double(truth.value ?? "") ?? .nan)) <= 0.5 {
                    v.caloriesMatched += 1
                }
            }
            if let truth = truthEntry(record, fid: "serving_size") {
                v.servingSizeTotal += 1
                if let parsed = outcome.parsed?.servingSize,
                   Self.normalize(parsed) == Self.normalize(truth.value ?? "") {
                    v.servingSizeMatched += 1
                }
            }
            if let truth = truthEntry(record, fid: "servings_per_container") {
                v.servingsTotal += 1
                if let parsed = outcome.parsed?.servingsPerContainer,
                   let expected = Double(truth.value ?? ""),
                   abs(parsed - expected) <= 0.01 {
                    v.servingsMatched += 1
                }
            }
            counts[k] = v
        }

        var families: [String: ReplayReport.FamilyReport] = [:]
        for (k, v) in counts {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            if families[parts[0]] == nil {
                families[parts[0]] = ReplayReport.FamilyReport(byVariant: [:])
            }
            families[parts[0]]!.byVariant[parts[1]] = v
        }

        return ReplayReport(
            records: records.count,
            groups: Set(records.map(\.group_id)).count,
            families: families
        )
    }

    /// First observable truth entry for `fid` on a serving-like basis, else the
    /// basis-less entry (serving size and servings-per-container carry no basis),
    /// else nil.
    static func truthEntry(_ record: CorpusRecord, fid: String) -> CorpusRecord.FieldEntry? {
        for basis in servingBases {
            if let entry = record.fields["\(fid)@\(basis)"], entry.observable, entry.value != nil {
                return entry
            }
        }
        if let entry = record.fields[fid], entry.observable, entry.value != nil {
            return entry
        }
        return nil
    }

    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":;,. "))
    }

    public static func reportJSON(_ report: ReplayReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(report)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
