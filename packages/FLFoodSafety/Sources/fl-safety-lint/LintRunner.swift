import Foundation
import FLFoodSafety

/// Driver-level failure: unreadable pattern data or a records set that needs
/// pattern data the driver was not pointed at. Distinct from any linter
/// finding — the linters never see a partially-initialised driver.
enum LintDriverError: Error, CustomStringConvertible {
    case driver(String)

    var description: String {
        switch self {
        case .driver(let message): return "fl-safety-lint: \(message)"
        }
    }
}

/// One canon finding on either surface, wrapped so the renderer and the
/// format checks stay on the canon format (`data/food-safety/README.md`):
/// file · record id · field · current text · required change (rewrite +
/// rule id + citation). The wrapper adds display plumbing only — kind,
/// rewrite and citation all come from the package linters.
enum CanonFinding {
    case step(LintFinding, file: String, recordID: String, field: String)
    case copy(CopyFinding)

    /// "step" or "copy" — which linter emitted the finding.
    var surface: String {
        switch self {
        case .step: return "step"
        case .copy: return "copy"
        }
    }

    /// The finding class: a `LintFinding.Kind` raw value for step findings,
    /// the `CopyLint` pattern id for copy findings.
    var kindName: String {
        switch self {
        case .step(let finding, _, _, _): return finding.kind.rawValue
        case .copy(let finding): return finding.patternID
        }
    }

    /// The canon-format line, prefixed with the kind for grep-ability.
    var line: String {
        switch self {
        case .step(let finding, let file, let recordID, let field):
            return "[\(finding.kind.rawValue)] " + finding.findingLine(file: file, recordID: recordID, field: field)
        case .copy(let finding):
            return "[\(finding.patternID)] " + finding.canonicalLine
        }
    }

    // Accessors for the universal finding-format checks (the conformance kit
    // asserts every finding cites a rule id and a citation and carries one
    // exact rewrite; review and fail-closed findings state what is missing).

    var ruleID: String {
        switch self {
        case .step(let finding, _, _, _): return finding.ruleID
        case .copy: return ""
        }
    }

    var patternID: String? {
        switch self {
        case .step: return nil
        case .copy(let finding): return finding.patternID
        }
    }

    var suggestedRewrite: String {
        switch self {
        case .step(let finding, _, _, _): return finding.suggestedRewrite
        case .copy(let finding): return finding.requiredChange
        }
    }

    var detail: String {
        switch self {
        case .step(let finding, _, _, _): return finding.detail
        case .copy: return ""
        }
    }

    var isFailClosedOrReview: Bool {
        switch self {
        case .step(let finding, _, _, _): return finding.kind == .failClosed || finding.kind == .flagForReview
        case .copy: return false
        }
    }

    /// Machine-readable projection for `--json` output.
    var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "surface": surface,
            "kind": kindName,
            "line": line,
        ]
        switch self {
        case .step(let finding, let file, let recordID, let field):
            out["file"] = file
            out["record_id"] = recordID
            out["field"] = field
            out["rule_id"] = finding.ruleID
            out["phrase"] = finding.phrase
            out["current_text"] = finding.currentText
            out["source_attribution"] = finding.sourceAttribution
            out["source_url"] = finding.sourceURL
            out["source_quote"] = finding.sourceQuote
            out["suggested_temp_f"] = finding.suggestedTempF
            out["suggested_rewrite"] = finding.suggestedRewrite
            out["detail"] = finding.detail
        case .copy(let finding):
            out["file"] = finding.file
            out["record_id"] = finding.recordID
            out["field"] = finding.field
            out["rule_id"] = NSNull()
            out["phrase"] = NSNull()
            out["current_text"] = finding.currentText
            out["source_attribution"] = NSNull()
            out["source_url"] = NSNull()
            out["source_quote"] = NSNull()
            out["suggested_temp_f"] = NSNull()
            out["suggested_rewrite"] = finding.requiredChange
            out["detail"] = NSNull()
        }
        return out
    }
}

/// The result of linting one records file.
struct LintRun {
    let recordCount: Int
    let findings: [CanonFinding]

    /// The CLI exit-code predicate: 0 when clean, 1 when findings exist.
    var isClean: Bool { findings.isEmpty }
}

/// Runs the package linters over decoded records. The runner holds no lint
/// rules and no phrasing knowledge: everything it reports comes from
/// `StepLinter.findingsForRecipe` or `CopyLint.lint`.
enum LintRunner {
    static func run(records: [LintInputRecord], rulebookData: Data?, patternsData: Data?) throws -> LintRun {
        let stepLinter = StepLinter(rulebookData: rulebookData)

        let needsPatterns = records.contains { record in
            if case .copy = record.surface { return true }
            return false
        }
        var copyLint: CopyLint?
        if needsPatterns {
            guard let patternsData else {
                throw LintDriverError.driver(
                    "the records contain copy records but no copy-lint pattern data is available — pass --patterns <copy-lint-patterns.json>"
                )
            }
            do {
                copyLint = try CopyLint(patternsData: patternsData)
            } catch {
                throw LintDriverError.driver("the copy-lint pattern data could not be loaded: \(error)")
            }
        }

        var findings: [CanonFinding] = []
        for record in records {
            switch record.surface {
            case .recipe(let title, let ingredients, let instructions, let safetyFields):
                for row in stepLinter.findingsForRecipe(
                    title: title, ingredients: ingredients,
                    instructions: instructions, safetyFields: safetyFields
                ) {
                    for finding in row.findings {
                        findings.append(.step(
                            finding, file: record.file, recordID: record.id,
                            field: "instructions[\(row.stepIndex + 1)]"
                        ))
                    }
                }
            case .copy(let field, let text):
                guard let copyLint else { continue }
                for finding in copyLint.lint([CopyRecord(file: record.file, recordID: record.id, field: field, text: text)]) {
                    findings.append(.copy(finding))
                }
            }
        }
        return LintRun(recordCount: records.count, findings: findings)
    }

    // MARK: Rendering

    /// Human output: one canon-format line per finding, then a summary.
    static func renderHuman(_ run: LintRun) -> String {
        var out: [String] = run.findings.map { $0.line }
        out.append("")
        out.append("Linted \(run.recordCount) record\(run.recordCount == 1 ? "" : "s"): \(run.findings.count) finding\(run.findings.count == 1 ? "" : "s")\(run.isClean ? " (clean)" : "").")
        return out.joined(separator: "\n")
    }

    /// Machine output: a stable JSON envelope (sorted keys, pretty printed).
    static func renderJSON(_ run: LintRun) throws -> String {
        let envelope: [String: Any] = [
            "command": "lint",
            "record_count": run.recordCount,
            "finding_count": run.findings.count,
            "clean": run.isClean,
            "findings": run.findings.map { $0.jsonObject },
        ]
        return try renderJSONData(envelope)
    }

    static func renderJSONData(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
