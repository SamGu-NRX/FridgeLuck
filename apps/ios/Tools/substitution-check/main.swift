import Foundation

// Portable check for apps/ios/FeatureLogic/Substitution/SubstitutionTable.swift
// against the generated canonical-key resource (substitutions-v2.json).
//
// Usage: substitution-check PATH_TO_SUBSTITUTIONS_V2_JSON

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
//    schemaVersion 2.0.0; the source table's 1.1.0 rides in `source`.
//    The reviewed overhaul table has 279 pairs; canonical-key mapping ships
//    70 of them (2x the legacy app-id table's 35) with 126 of 317 endpoints
//    resolved by exact evidence.
try require(document.schemaVersion == "2.0.0", "schemaVersion must be 2.0.0")
try require(document.source.tableSchemaVersion == "1.1.0",
  "source tableSchemaVersion: \(document.source.tableSchemaVersion ?? "nil")")
try require(document.audit.pairsTotal == 279, "pairsTotal: \(document.audit.pairsTotal)")
try require(document.audit.pairsShipped == document.swaps.count,
  "pairsShipped \(document.audit.pairsShipped) != swaps \(document.swaps.count)")
try require(document.audit.pairsShipped + document.audit.pairsDropped == document.audit.pairsTotal,
  "shipped + dropped must equal total")
try require(document.audit.mappedIngredients == 126, "mappedIngredients: \(document.audit.mappedIngredients)")
try require(document.audit.pairsShipped == 70, "pairsShipped: \(document.audit.pairsShipped)")
try require(document.audit.pairsShipped > 35, "canonical-key coverage must beat the legacy table")
try require(document.audit.compositionKnownSubstitutes == 50,
  "compositionKnownSubstitutes: \(document.audit.compositionKnownSubstitutes ?? -1)")

// 2. Determinism: two decodes are equal.
let second = try SubstitutionTable(data: data)
try require(second.document == document, "re-decode must be identical")

// 3. Canonical-key integrity: no self-swaps, no duplicate key/role offers,
//    every swap endpoint has composition facts, and the index resolves by
//    original key.
var offers = Set<String>()
for swap in document.swaps {
  try require(swap.originalKey != swap.substituteKey,
    "\(swap.pairId): canonicalization must not create self-swaps")
  try require(offers.insert("\(swap.originalKey)|\(swap.substituteKey)|\(swap.role)").inserted,
    "\(swap.pairId): duplicate key/role offer")
  try require(document.compositions[swap.originalKey] != nil,
    "\(swap.pairId): original \(swap.originalKey) missing from compositions")
  try require(document.compositions[swap.substituteKey] != nil,
    "\(swap.pairId): substitute \(swap.substituteKey) missing from compositions")
  try require(!table.swaps(forCanonical: swap.originalKey).isEmpty,
    "\(swap.pairId): original must index")
}
try require(table.swaps(forCanonical: "not-a-key").isEmpty, "unknown key must resolve empty")
try require(!table.originalKeys.isEmpty, "table must index at least one original key")

// 4. Difference text never promises "no change" (SPEC §3.1).
for swap in document.swaps {
  let lowered = swap.difference.lowercased()
  try require(!lowered.contains("no change"), "\(swap.pairId): difference promises no change")
  try require(!swap.sourceIds.isEmpty, "\(swap.pairId): needs at least one source")
}

// 5. Unknown composition fails closed to EMPTY class lists in the artifact
//    itself (no half-known compositions), and the per-swap recheck matches
//    the top-level composition facts for the substitute key.
for swap in document.swaps {
  let facts = document.compositions[swap.substituteKey]
  try require(facts != nil, "\(swap.pairId): substitute composition missing")
  if !swap.recheck.compositionKnown {
    try require(swap.recheck.allergenClasses.isEmpty && swap.recheck.dietClasses.isEmpty,
      "\(swap.pairId): unknown composition must ship empty classes")
    try require(facts?.compositionKnown == false,
      "\(swap.pairId): recheck unknown but compositions claims known")
  } else {
    try require(facts?.compositionKnown == true,
      "\(swap.pairId): recheck known but compositions claims unknown")
    try require(swap.recheck.allergenClasses == facts?.allergenClasses &&
      swap.recheck.dietClasses == facts?.dietClasses,
      "\(swap.pairId): recheck classes diverge from compositions")
  }
}

// 6. The screen: all shipped swaps x all table restrictions. A swap whose
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
      refusedCount += 1
      try require(named == offending,
        "\(swap.pairId) under \(name): refused \(named) but expected \(offending)")
    }
  }
  // No restrictions: everything screens allowed.
  if case .allowed = table.screen(swap, restrictions: []) {} else {
    throw CheckFailure(description: "\(swap.pairId): empty restrictions must allow")
  }
  // Unknown restriction ids contribute no forbids: known-composition swaps
  // stay allowed, unknown-composition swaps still fail closed to askUser
  // (an active dietary context exists, so unknown blocks, LeChef §7).
  let unknownIDOutcome = table.screen(swap, restrictions: ["keto", "low_carb"])
  switch (swap.recheck.compositionKnown, unknownIDOutcome) {
  case (true, .allowed):
    break
  case (false, .askUser):
    break
  default:
    throw CheckFailure(
      description:
        "\(swap.pairId): unknown restriction ids must add no forbids (known→allowed, unknown→askUser), got \(unknownIDOutcome)"
    )
  }
}
try require(refusedCount > 0, "sweep must refuse at least one pair-restriction case")
try require(allowedCount > 0, "sweep must allow at least one pair-restriction case")
try require(askUserCount > 0, "sweep must surface ask-the-user states (unknown composition ships)")

// 7. Reviewer examples from the PR #114 review, over the shipped resource.
//    Compound closure: the substitute's screening carries the full class list
//    (yogurt carries dairy; tofu carries soy), so the swap is refused for the
//    eaters the component concerns. (v2 ships no butter substitute — the
//    reviewed pairs run butter→yogurt direction, not the reverse.)
let yogurtSubstitutes = document.swaps.filter { $0.substituteKey == "yogurt" }
try require(!yogurtSubstitutes.isEmpty, "expected at least one yogurt substitute")
for swap in yogurtSubstitutes {
  try require(swap.recheck.allergenClasses.contains("dairy"),
    "\(swap.pairId): yogurt substitute must carry dairy")
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

// 8. Evidence verdicts stay honest: every fit's verdict comes from the
//    table's allowed set, and the primary role fit exists.
for swap in document.swaps {
  let primary = SubstitutionTable.primaryVerdict(of: swap)
  try require(primary != nil && !primary!.isEmpty, "\(swap.pairId): primary verdict required")
  for fit in swap.fits {
    try require(["verified", "plausible", "unknown", "unsupported"].contains(fit.verdict),
      "\(swap.pairId): verdict \(fit.verdict) outside the allowed set")
  }
}

// 9. Lookup by a known canonical original: egg ships the banana binder swap.
let eggSwaps = table.swaps(forCanonical: "egg")
try require(!eggSwaps.isEmpty, "egg must have shipped swaps")
try require(eggSwaps.contains { $0.substituteKey == "banana" },
  "egg must ship the mashed-banana pair")

print("substitution-check: OK — \(document.swaps.count) swaps, \(document.audit.mappedIngredients) mapped endpoints, \(document.compositions.count) composition keys, sweep allowed=\(allowedCount) askUser=\(askUserCount) refused=\(refusedCount)")
}

do {
  try run(arguments[1])
} catch {
  FileHandle.standardError.write("substitution-check: FAILED — \(error)\n".data(using: .utf8)!)
  exit(1)
}
