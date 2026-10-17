import Foundation
import FLFoodSafety

// flfoodsafety-audit — regenerates data/food-safety/BUNDLED-RECIPE-AUDIT.md
// from the repo checkout. Byte-reproducible: output depends only on the
// rulebook and the bundled data.json (see BundledRecipeAudit.renderReport).
//
//   swift build -c release --package-path packages/FLFoodSafety
//   packages/FLFoodSafety/.build/release/flfoodsafety-audit --repo-root . \
//       > data/food-safety/BUNDLED-RECIPE-AUDIT.md

let usage = """
flfoodsafety-audit — regenerate data/food-safety/BUNDLED-RECIPE-AUDIT.md

Usage:
  flfoodsafety-audit --repo-root <path-to-fridgeluck-checkout>

Writes the audit markdown to stdout. Exits non-zero with the schema
violations when rules.json or data.json fails to parse or validate.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("flfoodsafety-audit: \(message)\n").utf8))
    exit(2)
}

var repoRoot = "."
var arguments = Array(CommandLine.arguments.dropFirst())
while let arg = arguments.first {
    arguments.removeFirst()
    switch arg {
    case "--repo-root":
        guard let value = arguments.first else { fail("--repo-root requires a value") }
        repoRoot = value
        arguments.removeFirst()
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(arg)\n\(usage)")
    }
}

do {
    let rulesData = try Data(contentsOf: URL(fileURLWithPath: repoRoot + "/data/food-safety/rules.json"))
    let rulebook = try Rulebook.decode(rulesData)
    let data = try BundledRecipeAudit.loadBundledData(path: repoRoot + "/apps/ios/Resources/data.json")
    print(BundledRecipeAudit.renderReport(rulebook: rulebook, data: data), terminator: "")
} catch let error as RulebookError {
    FileHandle.standardError.write(Data(("flfoodsafety-audit: \(error)\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("flfoodsafety-audit: \(error)\n").utf8))
    exit(1)
}
