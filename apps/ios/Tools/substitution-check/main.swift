import Foundation

// Portable check for apps/ios/FeatureLogic/Substitution/SubstitutionTable.swift
// against the generated app resource (substitutions-v1.json).
//
// Usage: substitution-check PATH_TO_SUBSTITUTIONS_V1_JSON

struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CheckFailure(description: message) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write("usage: substitution-check SUBSTITUTIONS_JSON\n".data(using: .utf8)!)
  exit(2)
}

func run(_ resourcePath: String) throws {
    let resourceURL = URL(fileURLWithPath: resourcePath)
    let data = try Data(contentsOf: resourceURL)
let table = try SubstitutionTable(data: data)
let document = table.document

// 1. Schema gate and audit coverage. The resource's own contract is
//    schemaVersion 1.0.0; the source table's 1.1.0 rides in `source`.
try require(document.schemaVersion == "1.0.0", "schemaVersion must be 1.0.0")
try require(document.source.tableSchemaVersion == "1.1.0",
  "source tableSchemaVersion: \(document.source.tableSchemaVersion ?? "nil")")
try require(document.audit.pairsTotal == 279, "pairsTotal: \(document.audit.pairsTotal)")
try require(document.audit.pairsShipped == document.swaps.count,
  "pairsShipped \(document.audit.pairsShipped) != swaps \(document.swaps.count)")
try require(document.audit.pairsShipped + document.audit.pairsDropped == document.audit.pairsTotal,
  "shipped + dropped must equal total")
try require(document.audit.mappedIngredients == 40, "mappedIngredients: \(document.audit.mappedIngredients)")
try require(document.audit.pairsShipped == 35, "pairsShipped: \(document.audit.pairsShipped)")

// 2. Determinism: two decodes are equal.
let second = try SubstitutionTable(data: data)
try require(second.document == document, "re-decode must be identical")

// 3. Every swap references a mapped, distinct app ingredient id pair, and the
//    index resolves by original id.
for swap in document.swaps {
  try require(swap.originalId > 0 && swap.substituteId > 0,
    "\(swap.pairId): app ids must be positive")
  try require(!table.swaps(for: swap.originalId).isEmpty,
    "\(swap.pairId): original must index")
}
try require(table.swaps(for: 99_999).isEmpty, "unknown id must resolve empty")

// 4. Difference text never promises "no change" (SPEC §3.1).
for swap in document.swaps {
  let lowered = swap.difference.lowercased()
  try require(!lowered.contains("no change"), "\(swap.pairId): difference promises no change")
  try require(!swap.sourceIds.isEmpty, "\(swap.pairId): needs at least one source")
}

// 5. The screen: all shipped swaps x all table restrictions. A swap whose
//    substitute carries a forbidden class must never screen allowed
//    (compound closure included); unknown composition must ask the user.
var allowedCount = 0
var askUserCount = 0
var refusedCount = 0
for swap in document.swaps {
  for (name, screen_) in document.restrictions.sorted(by: { $0.key < $1.key }) {
    let outcome = table.screen(swap, restrictions: [name])
    let carried = Set(swap.recheck.allergenClasses).union(swap.recheck.dietClasses)
    let offending = carried.intersection(screen_.forbids).sorted()
    switch outcome {
    case .allowed:
      allowedCount += 1
      try require(offending.isEmpty,
        "\(swap.pairId) offered under \(name) despite forbidden \(offending)")
    case .askUser:
      askUserCount += 1
      try require(!swap.recheck.compositionKnown,
        "\(swap.pairId): askUser without unknown composition under \(name)")
    case .refused(let named):
      askUserCount += 0
      refusedCount += 1
      try require(named == offending,
        "\(swap.pairId) under \(name): refused \(named) but expected \(offending)")
    }
  }
  // No restrictions: everything screens allowed.
  if case .allowed = table.screen(swap, restrictions: []) {} else {
    throw CheckFailure(description: "\(swap.pairId): empty restrictions must allow")
  }
  // Unknown restriction ids screen nothing.
  if case .allowed = table.screen(swap, restrictions: ["keto", "low_carb"]) {} else {
    throw CheckFailure(description: "\(swap.pairId): unknown restriction must not screen")
  }
}
try require(refusedCount > 0, "sweep must refuse at least one pair-restriction case")
try require(allowedCount > 0, "sweep must allow at least one pair-restriction case")

// 6. Reviewer examples from the PR #114 review, over the shipped resource.
//    Compound closure: the substitute's screening carries the full class list
//    (olive-oil-to-butter carries dairy; tofu carries soy), so the swap is
//    refused for the eaters the component concerns.
let butterSubstitutes = document.swaps.filter { $0.substituteKey == "butter" }
try require(!butterSubstitutes.isEmpty, "expected at least one butter substitute")
for swap in butterSubstitutes {
  try require(swap.recheck.allergenClasses.contains("dairy"),
    "\(swap.pairId): butter substitute must carry dairy")
  if case .refused(let offending) = table.screen(swap, restrictions: ["vegan"]) {
    try require(offending.contains("dairy"),
      "\(swap.pairId): vegan refusal must name dairy, got \(offending)")
  } else {
    throw CheckFailure(description: "\(swap.pairId): must refuse for vegan eaters")
  }
}
let tofuSubstitutes = document.swaps.filter { $0.substituteKey == "tofu" }
try require(!tofuSubstitutes.isEmpty, "expected at least one tofu substitute")
for swap in tofuSubstitutes {
  try require(swap.recheck.allergenClasses.contains("soy"),
    "\(swap.pairId): tofu substitute must carry soy")
  if case .refused = table.screen(swap, restrictions: ["soy-free"]) {} else {
    throw CheckFailure(description: "\(swap.pairId): must refuse for soy-free eaters")
  }
  // The same swap stays allowed for eaters the component does not concern.
  if case .allowed = table.screen(swap, restrictions: ["gluten-free"]) {} else {
    throw CheckFailure(description: "\(swap.pairId): must stay allowed for gluten-free eaters")
  }
}

// 7. Evidence verdicts stay honest: no swap's primary fit is "unknown" while
//    claiming a verified primary verdict, and verdicts come only from the
//    table's allowed set.
for swap in document.swaps {
  let primary = SubstitutionTable.primaryVerdict(of: swap)
  try require(primary != nil && !primary!.isEmpty, "\(swap.pairId): primary verdict required")
  for fit in swap.fits {
    try require(["verified", "plausible", "unknown", "unsupported"].contains(fit.verdict),
      "\(swap.pairId): verdict \(fit.verdict) outside the allowed set")
  }
}

// 8. Lookup by a known original: egg (id 1) ships the banana binder swap.
let eggSwaps = table.swaps(for: 1)
try require(!eggSwaps.isEmpty, "egg must have shipped swaps")
try require(eggSwaps.contains { $0.substituteKey == "banana" },
  "egg must ship the mashed-banana pair")

print("substitution-check: OK — \(document.swaps.count) swaps, \(document.audit.mappedIngredients) mapped ingredients, sweep allowed=\(allowedCount) askUser=\(askUserCount) refused=\(refusedCount)")
}

do {
  try run(arguments[1])
} catch {
  FileHandle.standardError.write("substitution-check: FAILED — \(error)\n".data(using: .utf8)!)
  exit(1)
}
