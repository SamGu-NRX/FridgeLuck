import Foundation

// fl-safety-lint — the FridgeLuck food-safety canon conformance CLI.
//
// A thin driver over the FLFoodSafety linters: it reads the records file it
// is pointed at, runs `StepLinter` and `CopyLint` over them, and prints one
// canon-format finding per violation (file · record id · field · current
// text · required change, with rule id and citation). It contains no lint
// rules of its own and reads no data files except those it is pointed at.
//
//   fl-safety-lint lint <records.json> [--rules <rules.json>]
//       [--patterns <copy-lint-patterns.json>] [--json]
//   fl-safety-lint conformance <dir> [--rules <rules.json>]
//       [--patterns <copy-lint-patterns.json>] [--json]
//
// Exit codes:
//   0  clean input / conformance passed
//   1  findings emitted / conformance failed
//   2  usage error
//   3  input/output or format error

let usage = """
fl-safety-lint — the FridgeLuck food-safety canon conformance CLI

Usage:
  fl-safety-lint lint <records.json> [--rules <rules.json>] [--patterns <patterns.json>] [--json]
  fl-safety-lint conformance <dir> [--rules <rules.json>] [--patterns <patterns.json>] [--json]
  fl-safety-lint --help

Commands:
  lint         Lint one records file (recipe and copy records; see
               data/food-safety/conformance/README.md for the format) and
               print one canon-format finding per violation. Human-readable
               by default, --json for machine output.
  conformance  Run the conformance kit: every fixture case is replayed and
               compared to the finding kinds it declares, the true negatives
               and the clean replay must produce zero findings, and the kit
               must cover every finding class the linters can emit.

Options:
  --rules      Path to rules.json. Default: data/food-safety/rules.json,
               found by walking up from the working directory. Rules data
               that is missing or undecodable fails closed (clause 7):
               lint emits failClosed findings that say what is missing.
  --patterns   Path to copy-lint-patterns.json. Default:
               data/food-safety/copy-lint-patterns.json, found the same way.
               Needed only when copy records are present; unreadable pattern
               data is an input/output error (the copy lint has no
               fail-closed mode to degrade into).
  --json       Machine-readable output.
  -h, --help   Show this help.

Exit codes:
  0  clean / conformance passed
  1  findings emitted / conformance failed
  2  usage error
  3  input/output or format error
"""

func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fl-safety-lint: \(message)\n".utf8))
    exit(2)
}

func failIO(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fl-safety-lint: \(message)\n".utf8))
    exit(3)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("fl-safety-lint: \(message)\n".utf8))
}

// MARK: Argument parsing

var command: String?
var positional: [String] = []
var rulesArg: String?
var patternsArg: String?
var jsonOutput = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let arg = arguments.first {
    arguments.removeFirst()
    switch arg {
    case "--rules":
        guard let value = arguments.first else { failUsage("--rules requires a value") }
        rulesArg = value
        arguments.removeFirst()
    case "--patterns":
        guard let value = arguments.first else { failUsage("--patterns requires a value") }
        patternsArg = value
        arguments.removeFirst()
    case "--json":
        jsonOutput = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        if arg.hasPrefix("-") && arg != "-" {
            failUsage("unknown argument \(arg)\n\n\(usage)")
        }
        if command == nil {
            command = arg
        } else {
            positional.append(arg)
        }
    }
}

guard let command else {
    failUsage("no command given (lint or conformance)\n\n\(usage)")
}
guard command == "lint" || command == "conformance" else {
    failUsage("unknown command '\(command)' (lint or conformance)\n\n\(usage)")
}
guard !positional.isEmpty else {
    failUsage("command '\(command)' requires a path argument\n\n\(usage)")
}
guard positional.count == 1 else {
    failUsage("command '\(command)' takes exactly one path argument\n\n\(usage)")
}
let targetPath = positional[0]

// MARK: Default data resolution (repo-root walk-up)

/// Walks up from `start` looking for `relativePath`; the first ancestor that
/// contains it wins. The typical invocation runs from the repository root or
/// a subdirectory of it, so the canon data is found without flags.
func findDefault(_ relativePath: String, from start: String) -> String? {
    var dir = URL(fileURLWithPath: start, isDirectory: true).standardized
    for _ in 0...64 {
        let candidate = dir.appendingPathComponent(relativePath).path
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { return nil }
        dir = parent
    }
    return nil
}

/// Loads rules data for the linter. Per canon clause 7 the RULES side never
/// errors out: unreadable or undecodable data is handed to the fail-closed
/// linter, whose findings say exactly what is missing (and make the run exit
/// non-zero). Returns the data (nil when the rulebook is missing) and any
/// note worth printing to stderr.
func loadRulebookData(explicit: String?) -> (data: Data?, note: String?) {
    if let explicit {
        if let data = FileManager.default.contents(atPath: explicit) {
            return (data, nil)
        }
        return (nil, "rules file at \(explicit) could not be read — linting fails closed (clause 7)")
    }
    guard let found = findDefault("data/food-safety/rules.json", from: FileManager.default.currentDirectoryPath) else {
        return (nil, "no data/food-safety/rules.json found walking up from the working directory — linting fails closed (clause 7); pass --rules to point at the rulebook")
    }
    if let data = FileManager.default.contents(atPath: found) {
        return (data, nil)
    }
    return (nil, "rules file at \(found) could not be read — linting fails closed (clause 7)")
}

/// Loads copy-lint pattern data, needed only for copy records. `CopyLint` has
/// no fail-closed mode to degrade into, so unreadable pattern data is a
/// driver error (CLI exit 3), never a silent narrowing of the policy.
func loadPatternsData(explicit: String?) throws -> Data? {
    let path: String
    if let explicit {
        path = explicit
    } else if let found = findDefault("data/food-safety/copy-lint-patterns.json", from: FileManager.default.currentDirectoryPath) {
        path = found
    } else {
        throw LintDriverError.driver(
            "no copy-lint pattern data found walking up from the working directory — pass --patterns <copy-lint-patterns.json>"
        )
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw LintDriverError.driver("copy-lint pattern file at \(path) could not be read")
    }
    return data
}

// MARK: Commands

switch command {
case "lint":
    let rules = loadRulebookData(explicit: rulesArg)
    if let noteText = rules.note { note(noteText) }

    let recordsData: Data
    do {
        recordsData = try Data(contentsOf: URL(fileURLWithPath: targetPath))
    } catch {
        failIO("cannot read records file \(targetPath): \(error)")
    }
    let records: [LintInputRecord]
    do {
        records = try RecordsFormat.decode(recordsData)
    } catch let error as RecordsFormatError {
        failIO("\(error)")
    } catch {
        failIO("\(error)")
    }

    do {
        let needsPatterns = records.contains { $0.isCopy }
        let patternsData = needsPatterns ? try loadPatternsData(explicit: patternsArg) : nil
        let run = try LintRunner.run(records: records, rulebookData: rules.data, patternsData: patternsData)
        if jsonOutput {
            print(try LintRunner.renderJSON(run))
        } else {
            print(LintRunner.renderHuman(run))
        }
        exit(run.isClean ? 0 : 1)
    } catch let error as LintDriverError {
        failIO("\(error)")
    } catch {
        failIO("\(error)")
    }

case "conformance":
    let rules = loadRulebookData(explicit: rulesArg)
    if let noteText = rules.note { note(noteText) }

    do {
        // The kit always includes copy-lint cases, so pattern data is required.
        let patternsData = try loadPatternsData(explicit: patternsArg)
        let report = try ConformanceKit.run(directory: targetPath, rulebookData: rules.data, patternsData: patternsData)
        if jsonOutput {
            print(try ConformanceKit.renderJSON(report))
        } else {
            print(ConformanceKit.renderHuman(report))
        }
        exit(report.ok ? 0 : 1)
    } catch let error as ConformanceKit.ContentError {
        failIO("\(error)")
    } catch let error as LintDriverError {
        failIO("\(error)")
    } catch {
        failIO("\(error)")
    }

default:
    failUsage("unreachable command")
}
