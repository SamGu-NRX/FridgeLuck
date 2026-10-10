import XCTest

@testable import LabelNumbersReplay

/// Executed against the generated corpus in `../corpus` so the replay always
/// runs the exact data the Python tooling validates.
final class ReplayTests: XCTestCase {
    static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LabelNumbersReplayTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // SwiftReplay
        .deletingLastPathComponent()   // label-numbers-eval
        .appendingPathComponent("corpus/labels.jsonl")

    static let corpus: [CorpusRecord] = {
        do {
            return try CorpusReplay.loadCorpus(path: corpusURL)
        } catch {
            fatalError("cannot load corpus at \(corpusURL): \(error)")
        }
    }()

    func testCorpusLoadsExpectedShape() throws {
        XCTAssertEqual(Self.corpus.count, 480)
        XCTAssertEqual(Set(Self.corpus.map(\.group_id)).count, 240)
        XCTAssertEqual(Set(Self.corpus.map(\.family)).count, 4)
        for record in Self.corpus {
            XCTAssertFalse(record.lines.isEmpty, record.record_id)
            XCTAssertFalse(record.fields.isEmpty, record.record_id)
        }
    }

    func testReplayIsDeterministic() throws {
        let first = CorpusReplay.run(records: Self.corpus)
        let second = CorpusReplay.run(records: Self.corpus)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try CorpusReplay.reportJSON(first), try CorpusReplay.reportJSON(second))
    }

    func testReportCoversEveryFamilyAndVariant() throws {
        let report = CorpusReplay.run(records: Self.corpus)
        XCTAssertEqual(report.records, 480)
        for family in ["ca_bilingual", "eu_per100g", "eu_per_portion", "us_dual_column"] {
            let familyReport = report.families[family]
            XCTAssertNotNil(familyReport, family)
            XCTAssertEqual(familyReport?.byVariant["clean"]?.records, 60, family)
            XCTAssertEqual(familyReport?.byVariant["corrupted"]?.records, 60, family)
        }
    }

    func testCleanUSLabelsExtractCaloriesEveryTime() throws {
        let report = CorpusReplay.run(records: Self.corpus)
        let usClean = try XCTUnwrap(report.families["us_dual_column"]?.byVariant["clean"])
        XCTAssertEqual(usClean.keywordPositive, 60)
        XCTAssertEqual(usClean.caloriesTotal, 60)
        XCTAssertEqual(usClean.caloriesMatched, 60)
    }

    /// The prediction dump covers every record in corpus order and keeps the
    /// abstention contract: when the parser returns nothing, every value is null.
    func testPredictionsCoverEveryRecordInOrder() throws {
        let predictions = CorpusReplay.predictions(records: Self.corpus)
        XCTAssertEqual(predictions.count, Self.corpus.count)
        for (prediction, record) in zip(predictions, Self.corpus) {
            XCTAssertEqual(prediction.record_id, record.record_id)
            XCTAssertEqual(prediction.family, record.family)
            XCTAssertEqual(prediction.variant_kind, record.variant_kind)
            if !prediction.parsed {
                XCTAssertNil(prediction.calories_per_serving, prediction.record_id)
                XCTAssertNil(prediction.serving_size, prediction.record_id)
                XCTAssertNil(prediction.servings_per_container, prediction.record_id)
            }
            if !prediction.keyword_positive {
                XCTAssertFalse(prediction.parsed, prediction.record_id)
            }
        }
    }

    func testPredictionsJSONLIsDeterministicAndComplete() throws {
        let first = try CorpusReplay.predictionsJSONL(CorpusReplay.predictions(records: Self.corpus))
        let second = try CorpusReplay.predictionsJSONL(CorpusReplay.predictions(records: Self.corpus))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.split(separator: "\n").count, 480)
        XCTAssertTrue(first.contains("\"LN-0001\""))
        XCTAssertTrue(first.contains("keyword_positive"))
    }
    /// Known production-parser gaps the corpus pins, so any parser change that
    /// alters them shows up here:
    /// - the serving-size capture is greedy and runs into the text that follows
    ///   ("Serving size 3 cookies (30 g) Amount per serving ..."), so the parsed
    ///   string never equals the truth value on a joined label;
    /// - the servings-per-container pattern expects the count *after* the phrase,
    ///   but every US label in the corpus reads "About 11 servings per container".
    func testKnownProductionServingGapsArePinned() throws {
        let report = CorpusReplay.run(records: Self.corpus)
        let usClean = try XCTUnwrap(report.families["us_dual_column"]?.byVariant["clean"])
        XCTAssertEqual(usClean.servingSizeTotal, 60)
        XCTAssertEqual(usClean.servingSizeMatched, 0)
        XCTAssertEqual(usClean.servingsTotal, 60)
        XCTAssertEqual(usClean.servingsMatched, 0)
    }

    /// EU nutrition declarations carry none of the US keyword set ("Calories",
    /// "serving size", "servings per container"), so the production keyword gate
    /// never flags them. Pinned so a keyword-set change is visible.
    func testEUKitchenKeywordGateIsNeverPositive() throws {
        let report = CorpusReplay.run(records: Self.corpus)
        XCTAssertEqual(report.families["eu_per100g"]?.byVariant["clean"]?.keywordPositive, 0)
        XCTAssertEqual(report.families["eu_per_portion"]?.byVariant["clean"]?.keywordPositive, 0)
    }

    func testAllRecordsParseWithoutCrashing() throws {
        for record in Self.corpus {
            _ = NutritionLabelParser.parse(ocrText: record.lines)
        }
    }

    func testExecutableProducesDeterministicReport() throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/LabelNumbersReplayTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SwiftReplay
        let corpusPath = Self.corpusURL.path

        func runOnce() throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = try XCTUnwrap(
                findExecutable(name: "label-numbers-replay", under: executable)
            )
            process.arguments = [corpusPath]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        func findExecutable(name: String, under root: URL) -> URL? {
            let fileManager = FileManager.default
            let candidates = [
                root.appendingPathComponent(".build/debug/\(name)"),
                root.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/\(name)"),
                root.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/\(name)"),
            ]
            return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
        }

        let first = try runOnce()
        let second = try runOnce()
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("\"records\" : 480"))
    }
}
