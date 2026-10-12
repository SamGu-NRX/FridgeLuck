import XCTest
import FLFoodSafety
@testable import fl_safety_lint

/// The conformance kit is the canon's self-test: these tests hold the shipped
/// kit in `data/food-safety/conformance/` to its own pinned expectations
/// through both the package linters and the `fl-safety-lint` runner, and
/// verify the decision inputs behind the CLI's exit codes (the usage-error
/// exit itself is a process-level `exit(2)` and cannot be tested in-process).
final class ConformanceTests: XCTestCase {
    // MARK: Repository paths

    /// Repo root, found by walking up from this source file until the canon
    /// data directory appears (immune to build-directory nesting).
    private var repoRoot: String {
        get throws {
            var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            while dir.path != "/" {
                if FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("data/food-safety/rules.json").path
                ) {
                    return dir.path
                }
                dir = dir.deletingLastPathComponent()
            }
            XCTFail("repo root with data/food-safety/rules.json not found above \(#filePath)")
            throw ConformanceError.path
        }
    }

    private enum ConformanceError: Error { case path }

    private var kitDirectory: String { get throws { try repoRoot + "/data/food-safety/conformance" } }

    private var defaultRulebookData: Data { get throws {
        let url = URL(fileURLWithPath: try repoRoot + "/data/food-safety/rules.json")
        return try XCTUnwrap(FileManager.default.contents(atPath: url.path), "cannot read \(url.path)")
    } }

    private var defaultPatternData: Data { get throws {
        let url = URL(fileURLWithPath: try repoRoot + "/data/food-safety/copy-lint-patterns.json")
        return try XCTUnwrap(FileManager.default.contents(atPath: url.path), "cannot read \(url.path)")
    } }

    /// Every kit case: the `cases-*.json` files plus `true-negatives.json`.
    private func allKitCases() throws -> [ConformanceKit.Case] {
        let directory = try kitDirectory
        let manager = FileManager.default
        let entries = try XCTUnwrap(try? manager.contentsOfDirectory(atPath: directory)).sorted()
        let fileNames = entries.filter { $0.hasPrefix("cases-") && $0.hasSuffix(".json") }
            + [ConformanceKit.trueNegativesFile]
        var cases: [ConformanceKit.Case] = []
        for fileName in fileNames {
            let data = try XCTUnwrap(
                manager.contents(atPath: directory + "/" + fileName),
                "cannot read \(fileName)"
            )
            cases.append(contentsOf: try ConformanceKit.decodeCaseFile(data, sourceFile: fileName))
        }
        return cases
    }

    /// Replays one kit case through the package linters directly (the same
    /// call the runner makes) and returns the findings wrapped in the CLI's
    /// canon-format finding.
    private func replay(_ kitCase: ConformanceKit.Case) throws -> [CanonFinding] {
        switch kitCase.record.surface {
        case .recipe(let title, let ingredients, let instructions, let safetyFields):
            let rulebookData: Data?
            switch kitCase.rulesOverride {
            case .none: rulebookData = try defaultRulebookData
            case .missingRulebook: rulebookData = nil
            case .data(let data): rulebookData = data
            }
            let linter = StepLinter(rulebookData: rulebookData)
            var wrapped: [CanonFinding] = []
            for row in linter.findingsForRecipe(
                title: title, ingredients: ingredients,
                instructions: instructions, safetyFields: safetyFields
            ) {
                for finding in row.findings {
                    wrapped.append(.step(
                        finding, file: kitCase.record.file, recordID: kitCase.record.id,
                        field: "instructions[\(row.stepIndex + 1)]"
                    ))
                }
            }
            return wrapped
        case .copy(let field, let text):
            let linter = try CopyLint(patternsData: try defaultPatternData)
            return linter.lint([CopyRecord(
                file: kitCase.record.file, recordID: kitCase.record.id, field: field, text: text
            )]).map { .copy($0) }
        }
    }

    // MARK: The shipped kit passes

    func testConformanceKitPassesOnRepositoryKit() throws {
        let report = try ConformanceKit.run(
            directory: try kitDirectory,
            rulebookData: try defaultRulebookData,
            patternsData: try defaultPatternData
        )
        XCTAssertTrue(
            report.ok,
            ConformanceKit.renderHuman(report)
        )
        // 30 error-class cases + 12 true negatives. Update when the kit grows.
        XCTAssertEqual(report.caseResults.count, 42, "the kit's case count changed; update this pin and the README inventory")
        XCTAssertTrue(report.replayProblems.isEmpty, "clean replay must produce zero findings")
        XCTAssertTrue(report.coverageProblems.isEmpty, "the kit must cover every finding class and copy pattern")
    }

    // MARK: Every error case: exact kinds, rule id, citation, rewrite

    func testEveryErrorCaseProducesExactKindsWithCitedRewrite() throws {
        for kitCase in try allKitCases() where !kitCase.expectedKinds.isEmpty {
            let findings = try replay(kitCase)
            let kinds = findings.map { finding -> String in
                if case .step(let stepFinding, _, _, _) = finding {
                    return stepFinding.kind.rawValue
                }
                if case .copy(let copyFinding) = finding {
                    return copyFinding.patternID
                }
                return ""
            }
            XCTAssertEqual(
                kinds, kitCase.expectedKinds,
                "case \(kitCase.id) (\(kitCase.sourceFile)) must pin its exact kind sequence"
            )
            for finding in findings {
                if finding.isFailClosedOrReview {
                    XCTAssertFalse(
                        finding.detail.isEmpty,
                        "case \(kitCase.id): \(finding.kindName) must state what is missing or what a reviewer must decide"
                    )
                } else if finding.patternID != nil {
                    XCTAssertTrue(
                        finding.suggestedRewrite.contains("(policy: ") && finding.suggestedRewrite.contains("retrieved "),
                        "case \(kitCase.id): copy finding does not cite its policy and source"
                    )
                } else {
                    XCTAssertFalse(
                        finding.ruleID.isEmpty,
                        "case \(kitCase.id): \(finding.kindName) carries no rule id"
                    )
                    XCTAssertFalse(
                        finding.suggestedRewrite.isEmpty,
                        "case \(kitCase.id): \(finding.kindName) carries no exact rewrite"
                    )
                    XCTAssertTrue(
                        finding.line.contains("source:") && finding.line.contains("retrieved"),
                        "case \(kitCase.id): \(finding.kindName) does not cite a source (rule id + citation required)"
                    )
                }
            }
        }
    }

    // MARK: True negatives and clean replay

    func testTrueNegativesProduceZeroFindings() throws {
        let cases = try allKitCases()
        let negatives = cases.filter { $0.expectedKinds.isEmpty }
        XCTAssertGreaterThanOrEqual(negatives.count, 9, "the kit must pin true negatives")
        for kitCase in negatives {
            let findings = try replay(kitCase)
            XCTAssertEqual(findings.count, 0, "true negative \(kitCase.id) must pass clean: \(findings.map { $0.kindName })")
        }
    }

    func testCleanReplayRecordsProduceZeroFindings() throws {
        let data = try XCTUnwrap(
            FileManager.default.contents(
                atPath: try kitDirectory + "/" + ConformanceKit.replayFile
            ),
            "cannot read the clean replay file"
        )
        let records = try RecordsFormat.decode(data)
        let run = try LintRunner.run(
            records: records,
            rulebookData: try defaultRulebookData,
            patternsData: try defaultPatternData
        )
        XCTAssertEqual(run.findings.count, 0, "the clean replay must produce zero findings")
        XCTAssertTrue(run.isClean)
    }

    // MARK: Exit-code decision inputs (usage errors are process-level exit(2))

    func testDirtyRecordsMakeLintRunUnclean() throws {
        // A records file with one violation drives exit 1: findings emitted.
        let dirty = #"""
        {"schema_version": 1, "description": "probe", "records": [{"kind": "recipe", "file": "probe.json", "id": "p1", "title": "Roast chicken", "ingredients": "1 whole chicken", "instructions": "1. Bake the chicken at 400 °F until done."}]}
        """#
        let records = try RecordsFormat.decode(Data(dirty.utf8))
        let run = try LintRunner.run(
            records: records,
            rulebookData: try defaultRulebookData,
            patternsData: try defaultPatternData
        )
        XCTAssertFalse(run.isClean, "a violating record must make the run unclean (exit 1)")
        XCTAssertEqual(run.findings.count, 1)
    }

    func testMissingKitDirectoryThrows() throws {
        XCTAssertThrowsError(
            try ConformanceKit.run(
                directory: "/tmp/fl-safety-lint-no-such-kit-\(UUID().uuidString)",
                rulebookData: try defaultRulebookData,
                patternsData: try defaultPatternData
            ),
            "a missing kit directory is an error, not a pass"
        )
    }

    func testBrokenKitCaseFileThrowsContentError() throws {
        // Undecodable kit content cannot run the kit at all (exit 3), and it
        // must not silently shrink the conformance surface to zero cases.
        let temp = NSTemporaryDirectory() + "fl-broken-kit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try Data("not json".utf8).write(to: URL(fileURLWithPath: temp + "/cases-broken.json"))
        XCTAssertThrowsError(
            try ConformanceKit.run(
                directory: temp,
                rulebookData: try defaultRulebookData,
                patternsData: try defaultPatternData
            )
        )
    }

    func testCoverageGateRejectsAKitThatStopsPinningPatterns() throws {
        // A kit missing its copy-lint case file must FAIL, not pass vacuously:
        // this is what makes adding a linter behaviour without a fixture a
        // conformance failure.
        let source = try kitDirectory
        let temp = NSTemporaryDirectory() + "fl-thin-kit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: temp) }
        for file in try FileManager.default.contentsOfDirectory(atPath: source) {
            if file.hasPrefix("cases-copy") { continue } // drop the copy pins
            try FileManager.default.copyItem(atPath: source + "/" + file, toPath: temp + "/" + file)
        }
        let report = try ConformanceKit.run(
            directory: temp,
            rulebookData: try defaultRulebookData,
            patternsData: try defaultPatternData
        )
        XCTAssertFalse(report.coverageProblems.isEmpty, "dropping the copy cases must be a coverage failure")
        XCTAssertFalse(report.ok)
    }
}
