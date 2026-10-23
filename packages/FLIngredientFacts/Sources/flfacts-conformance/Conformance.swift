// flfacts-conformance — runs data/ingredient-facts/conformance/cases.json
// through the real store and prints a per-case summary.
//
// Usage: flfacts-conformance <path-to-repo-root-or-data-dir> [cases.json]
//
// Exits 0 when every case matches, 1 otherwise.

import Foundation
import FLIngredientFacts

struct ConformanceCase: Codable {
    var id: String
    var ingredient: String
    var restrictions: Restrictions
    var expected: Expectation
    var note: String?

    struct Restrictions: Codable {
        var allergens: [String]?
        var diets: [String]?
    }

    struct Expectation: Codable {
        var result: String
        var reasonContains: [String]?
        var missingMention: [String]?
        var evidenceMention: [String]?
    }
}

struct CasesFile: Codable {
    var version: Int
    var cases: [ConformanceCase]
}

func makeRestrictions(_ raw: ConformanceCase.Restrictions) -> FLRestrictions {
    var result = FLRestrictions()
    for a in raw.allergens ?? [] {
        if let allergen = FLAllergen(rawValue: a) { result.allergens.insert(allergen) }
    }
    for d in raw.diets ?? [] {
        if let diet = FLDiet(rawValue: d) { result.diets.insert(diet) }
    }
    return result
}

func outcome(_ evaluation: FLEvaluation) -> String {
    switch evaluation {
    case .allowed: return "allowed"
    case .violated: return "violated"
    case .unknown: return "unknown"
    }
}

func reasonText(_ evaluation: FLEvaluation) -> String {
    switch evaluation {
    case .allowed: return ""
    case .violated(let violation): return violation.reason
    case .unknown(let unknown): return unknown.reason
    }
}

func missingTexts(_ evaluation: FLEvaluation) -> [String] {
    if case .unknown(let unknown) = evaluation { return unknown.missing }
    return []
}

func evidenceTexts(_ evaluation: FLEvaluation) -> [String] {
    if case .allowed(let evidence) = evaluation {
        return evidence.map { "\($0.kind.rawValue) \($0.ref) \($0.note)" }
    }
    return []
}

func run(arguments: [String]) -> Int32 {
    guard arguments.count >= 2 else {
        FileHandle.standardError.write("usage: flfacts-conformance <repo-root-or-data-dir> [cases.json]\n".data(using: .utf8)!)
        return 2
    }
    let root = URL(fileURLWithPath: arguments[1])
    let dataDir: URL
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("identities.json").path) {
        dataDir = root
    } else {
        dataDir = root.appendingPathComponent("data/ingredient-facts")
    }
    let casesURL: URL
    if arguments.count >= 3 {
        casesURL = URL(fileURLWithPath: arguments[2])
    } else {
        casesURL = dataDir.appendingPathComponent("conformance/cases.json")
    }

    let store: FLIngredientFactsStore
    do {
        store = try FLIngredientFactsStore(dataDirectory: dataDir)
    } catch {
        FileHandle.standardError.write("dataset load failed: \(error)\n".data(using: .utf8)!)
        return 2
    }

    let casesData: Data
    do {
        casesData = try Data(contentsOf: casesURL)
    } catch {
        FileHandle.standardError.write("cannot read \(casesURL.path): \(error)\n".data(using: .utf8)!)
        return 2
    }
    let cases: CasesFile
    do {
        cases = try JSONDecoder().decode(CasesFile.self, from: casesData)
    } catch {
        FileHandle.standardError.write("cannot decode \(casesURL.path): \(error)\n".data(using: .utf8)!)
        return 2
    }

    var failures = 0
    print("running \(cases.cases.count) conformance cases against \(dataDir.path)")
    for c in cases.cases {
        let evaluation = store.evaluate(
            ingredient: c.ingredient,
            restrictions: makeRestrictions(c.restrictions)
        )
        var problems: [String] = []
        if outcome(evaluation) != c.expected.result {
            problems.append("expected \(c.expected.result), got \(outcome(evaluation))")
        }
        if outcome(evaluation) == c.expected.result {
            let reason = reasonText(evaluation).lowercased()
            for needle in c.expected.reasonContains ?? [] {
                if !reason.contains(needle.lowercased()) {
                    problems.append("reason does not mention '\(needle)': \(reasonText(evaluation))")
                }
            }
            let missing = missingTexts(evaluation).map { $0.lowercased() }.joined(separator: "; ")
            for needle in c.expected.missingMention ?? [] {
                if !missing.contains(needle.lowercased()) {
                    problems.append("missing list does not mention '\(needle)': \(missing)")
                }
            }
            let evidence = evidenceTexts(evaluation).map { $0.lowercased() }.joined(separator: " | ")
            for needle in c.expected.evidenceMention ?? [] {
                if !evidence.contains(needle.lowercased()) {
                    problems.append("evidence does not mention '\(needle)': \(evidence)")
                }
            }
        }
        if problems.isEmpty {
            print("  PASS \(c.id): \(outcome(evaluation))")
        } else {
            failures += 1
            print("  FAIL \(c.id): \(problems.joined(separator: "; "))")
        }
    }

    if failures == 0 {
        print("all \(cases.cases.count) cases passed")
        return 0
    }
    print("\(failures) of \(cases.cases.count) cases failed")
    return 1
}

exit(run(arguments: CommandLine.arguments))
