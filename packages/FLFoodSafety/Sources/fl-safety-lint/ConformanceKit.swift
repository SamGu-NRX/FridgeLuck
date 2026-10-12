import Foundation
import FLFoodSafety

/// The conformance kit runner: replays `data/food-safety/conformance/` as a
/// self-test of the whole canon. Every fixture case is a small synthetic
/// record in the input shape the linters consume, plus the finding kinds it
/// must produce; the runner asserts reality against the pinned expectations
/// and that the kit covers every finding class the linters can emit.
///
/// The runner holds no lint rules of its own — it decodes fixtures, calls
/// `StepLinter` / `CopyLint`, and compares.
enum ConformanceKit {
    /// Files the kit requires (cases live in `cases-*.json`, name-sorted).
    static let trueNegativesFile = "true-negatives.json"
    static let replayFile = "replay-clean.json"
    static let caseFilePrefix = "cases-"

    /// A case-level rulebook override for the fail-closed cases: the default
    /// rulebook, no rulebook at all, or deliberately broken inline JSON.
    enum RulesOverride: Sendable {
        case none
        case missingRulebook
        case data(Data)
    }

    // MARK: Decoding

    struct Case: Sendable {
        let id: String
        let sourceFile: String
        let record: LintInputRecord
        let rulesOverride: RulesOverride
        let expectedKinds: [String]
        let expectedRuleID: String?
        let rewriteContains: [String]
        let detailContains: [String]
    }

    /// Kit content that cannot be decoded — the tool cannot run the kit at
    /// all (CLI exit 3, distinct from a conformance failure).
    struct ContentError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = "conformance kit error: \(description)" }
    }

    static func decodeCaseFile(_ data: Data, sourceFile: String) throws -> [Case] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContentError("\(sourceFile) is not valid JSON: \(error)")
        }
        guard let doc = raw as? [String: Any] else {
            throw ContentError("\(sourceFile) top level must be an object")
        }
        let allowed: Set<String> = ["schema_version", "name", "description", "cases"]
        let unknown = Set(doc.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ContentError("\(sourceFile): unknown key(s) \(unknown.sorted().joined(separator: ", "))")
        }
        guard (doc["schema_version"] as? Int) == 1 else {
            throw ContentError("\(sourceFile): schema_version must be 1, found: \(doc["schema_version"] ?? "missing")")
        }
        guard let cases = doc["cases"] as? [Any], !cases.isEmpty else {
            throw ContentError("\(sourceFile): cases must be a non-empty array")
        }
        return try cases.enumerated().map { index, item in
            try decodeCase(item, sourceFile: sourceFile, what: "cases[\(index)]")
        }
    }

    private static func decodeCase(_ raw: Any, sourceFile: String, what: String) throws -> Case {
        guard let dict = raw as? [String: Any] else {
            throw ContentError("\(sourceFile) \(what) must be an object")
        }
        let allowed: Set<String> = ["id", "record", "rules", "expect"]
        let unknown = Set(dict.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ContentError("\(sourceFile) \(what): unknown key(s) \(unknown.sorted().joined(separator: ", "))")
        }
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw ContentError("\(sourceFile) \(what): id is missing or empty")
        }
        guard let recordRaw = dict["record"] else {
            throw ContentError("\(sourceFile) \(what): record is missing")
        }
        let record = try RecordsFormat.decodeRecord(recordRaw, what: "\(sourceFile) \(what).record")

        let rulesOverride: RulesOverride
        let rulesRaw = dict["rules"]
        if rulesRaw == nil {
            rulesOverride = .none
        } else if rulesRaw is NSNull {
            rulesOverride = .missingRulebook
        } else if let broken = rulesRaw as? String {
            rulesOverride = .data(Data(broken.utf8))
        } else {
            throw ContentError("\(sourceFile) \(what): rules must be null (missing rulebook) or a string of deliberately broken JSON")
        }

        guard let expect = dict["expect"] as? [String: Any] else {
            throw ContentError("\(sourceFile) \(what): expect is missing (declare the finding kinds the case must produce)")
        }
        let expectAllowed: Set<String> = ["kinds", "rule_id", "rewrite_contains", "detail_contains"]
        let expectUnknown = Set(expect.keys).subtracting(expectAllowed)
        guard expectUnknown.isEmpty else {
            throw ContentError("\(sourceFile) \(what): unknown expect key(s) \(expectUnknown.sorted().joined(separator: ", "))")
        }
        guard let kinds = expect["kinds"] as? [String] else {
            throw ContentError("\(sourceFile) \(what): expect.kinds must be an array of finding-kind strings")
        }
        // Step findings are named by `LintFinding.Kind` raw values; copy
        // findings by `CopyLint` pattern id (checked against the loaded
        // pattern file during the coverage pass).
        if !record.isCopy {
            for kind in kinds {
                guard LintFinding.Kind(rawValue: kind) != nil else {
                    throw ContentError("\(sourceFile) \(what): unknown finding kind '\(kind)'")
                }
            }
        }
        return Case(
            id: id,
            sourceFile: sourceFile,
            record: record,
            rulesOverride: rulesOverride,
            expectedKinds: kinds,
            expectedRuleID: expect["rule_id"] as? String,
            rewriteContains: expect["rewrite_contains"] as? [String] ?? [],
            detailContains: expect["detail_contains"] as? [String] ?? []
        )
    }

    // MARK: Running

    struct CaseResult: Sendable {
        let caseID: String
        let sourceFile: String
        let ok: Bool
        let actualKinds: [String]
        let problems: [String]
    }

    struct Report {
        let caseResults: [CaseResult]
        let replayProblems: [String]
        /// Canon-coverage gaps: finding kinds or copy patterns no case pins.
        let coverageProblems: [String]

        var failedCases: Int { caseResults.filter { !$0.ok }.count }
        var passedCases: Int { caseResults.count - failedCases }
        var ok: Bool {
            failedCases == 0 && replayProblems.isEmpty && coverageProblems.isEmpty
        }
    }

    /// Runs the kit in `directory`. `rulebookData` and `patternsData` are the
    /// default data loaded by the driver (from `--rules` / `--patterns` or the
    /// repo-root walk-up); case-level overrides replace them per case.
    static func run(directory: String, rulebookData: Data?, patternsData: Data?) throws -> Report {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory) else {
            throw ContentError("conformance directory does not exist: \(directory)")
        }
        let entries = (try? manager.contentsOfDirectory(atPath: directory))?.sorted() ?? []
        let caseFiles = entries.filter { $0.hasPrefix(caseFilePrefix) && $0.hasSuffix(".json") }

        var replayProblems: [String] = []
        var coverageProblems: [String] = []

        var cases: [Case] = []
        var copyPatternExpectations: [String] = []
        if caseFiles.isEmpty {
            replayProblems.append("no \(caseFilePrefix)*.json case files found in \(directory) — the kit covers nothing")
        }
        for fileName in caseFiles {
            let path = directory + "/" + fileName
            guard let data = manager.contents(atPath: path) else {
                throw ContentError("cannot read \(path)")
            }
            for kitCase in try decodeCaseFile(data, sourceFile: fileName) {
                if kitCase.record.isCopy {
                    copyPatternExpectations.append(contentsOf: kitCase.expectedKinds)
                }
                cases.append(kitCase)
            }
        }

        // True negatives: cases whose expect is an empty kinds list.
        let trueNegativesPath = directory + "/" + trueNegativesFile
        if manager.fileExists(atPath: trueNegativesPath) {
            guard let data = manager.contents(atPath: trueNegativesPath) else {
                throw ContentError("cannot read \(trueNegativesPath)")
            }
            cases.append(contentsOf: try decodeCaseFile(data, sourceFile: trueNegativesFile))
        } else {
            replayProblems.append("the kit is missing \(trueNegativesFile) — true negatives must be pinned")
        }

        let caseResults: [CaseResult] = cases.map { runCase($0, rulebookData: rulebookData, patternsData: patternsData) }

        // Clean replay: the records-shaped file must produce zero findings.
        let replayPath = directory + "/" + replayFile
        if manager.fileExists(atPath: replayPath) {
            guard let data = manager.contents(atPath: replayPath) else {
                throw ContentError("cannot read \(replayPath)")
            }
            let records: [LintInputRecord]
            do {
                records = try RecordsFormat.decode(data)
            } catch let error as RecordsFormatError {
                throw ContentError("\(replayFile): \(error)")
            }
            let run = try LintRunner.run(records: records, rulebookData: rulebookData, patternsData: patternsData)
            for finding in run.findings {
                replayProblems.append("clean replay produced a finding (must be zero): \(finding.line)")
            }
        } else {
            replayProblems.append("the kit is missing \(replayFile) — the clean replay must be pinned")
        }

        // Coverage: every finding kind the package can emit, and every copy
        // pattern in the loaded pattern file, must be pinned by some case.
        let expected = Set(cases.flatMap { $0.expectedKinds })
        for kind in LintFinding.Kind.allCases where !expected.contains(kind.rawValue) {
            coverageProblems.append("the kit never pins finding kind '\(kind.rawValue)' — add a case to cases-*.json or true-negatives.json")
        }
        if let patternsData {
            do {
                let livePatterns = try CopyLint(patternsData: patternsData).patternIDs
                for pattern in livePatterns where !copyPatternExpectations.contains(pattern) {
                    coverageProblems.append("the kit never pins copy pattern '\(pattern)' — add a case to cases-copy-lint.json")
                }
            } catch {
                throw ContentError("the copy-lint pattern data could not be loaded: \(error)")
            }
        } else if cases.contains(where: { $0.record.isCopy }) {
            coverageProblems.append("the kit has copy cases but no pattern data was available — pass --patterns")
        }

        return Report(
            caseResults: caseResults,
            replayProblems: replayProblems,
            coverageProblems: coverageProblems
        )
    }

    private static func runCase(_ kitCase: Case, rulebookData: Data?, patternsData: Data?) -> CaseResult {
        var problems: [String] = []
        let actualKinds: [String]
        let findings: [CanonFinding]

        switch kitCase.record.surface {
        case .recipe(let title, let ingredients, let instructions, let safetyFields):
            let override: Data?
            switch kitCase.rulesOverride {
            case .none: override = rulebookData
            case .missingRulebook: override = nil
            case .data(let data): override = data
            }
            let linter = StepLinter(rulebookData: override)
            var kinds: [String] = []
            var wrapped: [CanonFinding] = []
            for row in linter.findingsForRecipe(
                title: title, ingredients: ingredients,
                instructions: instructions, safetyFields: safetyFields
            ) {
                for finding in row.findings {
                    kinds.append(finding.kind.rawValue)
                    wrapped.append(.step(
                        finding, file: kitCase.record.file, recordID: kitCase.record.id,
                        field: "instructions[\(row.stepIndex + 1)]"
                    ))
                }
            }
            actualKinds = kinds
            findings = wrapped
        case .copy(let field, let text):
            guard let patternsData else {
                return CaseResult(
                    caseID: kitCase.id, sourceFile: kitCase.sourceFile, ok: false,
                    actualKinds: [], problems: ["copy case but no pattern data available"]
                )
            }
            let linter: CopyLint
            do {
                linter = try CopyLint(patternsData: patternsData)
            } catch {
                return CaseResult(
                    caseID: kitCase.id, sourceFile: kitCase.sourceFile, ok: false,
                    actualKinds: [], problems: ["copy-lint pattern data could not be loaded: \(error)"]
                )
            }
            let found = linter.lint([CopyRecord(
                file: kitCase.record.file, recordID: kitCase.record.id, field: field, text: text
            )])
            actualKinds = found.map { $0.patternID }
            findings = found.map { .copy($0) }
        }

        // Exact kind sequence — the pin.
        if actualKinds != kitCase.expectedKinds {
            problems.append("expected kinds \(kitCase.expectedKinds), got \(actualKinds)")
        }
        // Rule id of a single finding.
        if let expectedRuleID = kitCase.expectedRuleID, findings.count == 1, findings[0].ruleID != expectedRuleID {
            problems.append("expected rule id '\(expectedRuleID)', got '\(findings[0].ruleID)'")
        }
        // The rewrite carries the declared substrings.
        for needle in kitCase.rewriteContains {
            let joined = findings.map { $0.suggestedRewrite }.joined(separator: " ")
            if !joined.contains(needle) {
                problems.append("no finding rewrite contains '\(needle)'")
            }
        }
        // The detail carries the declared substrings (fail-closed / review).
        for needle in kitCase.detailContains {
            let joined = findings.map { $0.detail }.joined(separator: " ")
            if !joined.contains(needle) {
                problems.append("no finding detail contains '\(needle)'")
            }
        }
        // Universal finding format: every finding cites a rule id (or policy
        // id) plus citation and carries one exact rewrite; review and
        // fail-closed findings state what is missing instead.
        for finding in findings {
            if finding.isFailClosedOrReview {
                if finding.detail.isEmpty {
                    problems.append("finding '\(finding.kindName)' must state what is missing or what a reviewer must decide (empty detail)")
                }
            } else if finding.patternID != nil {
                let change = finding.suggestedRewrite
                if !(change.contains("(policy: ") && change.contains("retrieved ")) {
                    problems.append("copy finding '\(finding.patternID ?? "")' does not cite its policy and source")
                }
            } else {
                if finding.ruleID.isEmpty {
                    problems.append("finding '\(finding.kindName)' carries no rule id")
                }
                if finding.suggestedRewrite.isEmpty {
                    problems.append("finding '\(finding.kindName)' carries no exact rewrite")
                }
                let line = finding.line
                if !line.contains("source:") || !line.contains("retrieved") {
                    problems.append("finding '\(finding.kindName)' does not cite a source (rule id + citation required)")
                }
            }
        }

        return CaseResult(
            caseID: kitCase.id, sourceFile: kitCase.sourceFile,
            ok: problems.isEmpty, actualKinds: actualKinds, problems: problems
        )
    }

    // MARK: Rendering

    static func renderHuman(_ report: Report) -> String {
        var out: [String] = []
        for result in report.caseResults {
            if result.ok {
                out.append("PASS \(result.caseID)")
            } else {
                out.append("FAIL \(result.caseID) (\(result.sourceFile))")
                for problem in result.problems {
                    out.append("       \(problem)")
                }
            }
        }
        for problem in report.replayProblems {
            out.append("FAIL clean-replay: \(problem)")
        }
        for problem in report.coverageProblems {
            out.append("FAIL coverage: \(problem)")
        }
        out.append("")
        out.append("Conformance: \(report.caseResults.count) cases, \(report.passedCases) passed, \(report.failedCases) failed; clean replay: \(report.replayProblems.isEmpty ? "zero findings" : "failed"); \(report.ok ? "kit self-test PASSED" : "kit self-test FAILED").")
        return out.joined(separator: "\n")
    }

    static func renderJSON(_ report: Report) throws -> String {
        let envelope: [String: Any] = [
            "command": "conformance",
            "case_count": report.caseResults.count,
            "passed": report.passedCases,
            "failed": report.failedCases,
            "ok": report.ok,
            "results": report.caseResults.map { result in
                [
                    "case": result.caseID,
                    "file": result.sourceFile,
                    "ok": result.ok,
                    "actual_kinds": result.actualKinds,
                    "problems": result.problems,
                ] as [String: Any]
            },
            "replay_problems": report.replayProblems,
            "coverage_problems": report.coverageProblems,
        ]
        return try LintRunner.renderJSONData(envelope)
    }
}

extension LintInputRecord {
    /// True when the record is a copy record (copy-lint surface).
    var isCopy: Bool {
        if case .copy = surface { return true }
        return false
    }
}
