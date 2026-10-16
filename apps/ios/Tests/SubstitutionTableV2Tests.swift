import FLFeatureLogic
import XCTest

/// Schema v2 table semantics: canonical-key decode, the schema gate, key-space
/// lookup, composition screening (compound closure + fail-closed unknown), and
/// determinism — with an inline miniature document so failures are readable.
final class SubstitutionTableV2Tests: XCTestCase {
  // MARK: - Fixture

  /// A miniature substitutions-v2.json exercising the decode and screen rules.
  private func makeV2JSON() -> Data {
    let json = """
      {
        "schemaVersion": "2.0.0",
        "allergenClasses": ["dairy", "soy", "gluten", "fish"],
        "roles": ["fat", "protein", "umami", "binder", "thickener"],
        "restrictions": {
          "vegan": {"forbids": ["dairy", "egg", "fish", "flesh_fish"]},
          "gluten-free": {"forbids": ["gluten"]},
          "soy-free": {"forbids": ["soy"]},
          "dairy-free": {"forbids": ["dairy"]}
        },
        "source": {
          "sourceCommit": "4b5895409cb1c990a5e8251f490fe80ccd35c295",
          "table": "data/substitutions/pairs.json",
          "tableBranch": "overhaul/substitution-table",
          "tableCreated": "2026-10-11",
          "tableSchemaVersion": "1.1.0",
          "vocabulary": "data/ingredients/vocabulary.json"
        },
        "audit": {
          "referencedIngredients": 4,
          "mappedIngredients": 4,
          "pairsTotal": 2,
          "pairsShipped": 2,
          "pairsDropped": 0,
          "compositionKnownSubstitutes": 1,
          "mappedKeys": ["butter", "yogurt", "cornstarch", "mystery_powder"],
          "unmappedKeys": [],
          "unmappedIngredients": 0
        },
        "compositions": {
          "butter": {
            "compositionKnown": true,
            "allergenClasses": ["dairy"],
            "dietClasses": ["animal", "animal_product", "dairy_animal"],
            "allergenNote": "Milk product."
          },
          "yogurt": {
            "compositionKnown": true,
            "allergenClasses": ["dairy"],
            "dietClasses": ["animal", "animal_product", "dairy_animal"],
            "allergenNote": null
          },
          "cornstarch": {
            "compositionKnown": true,
            "allergenClasses": [],
            "dietClasses": ["plant"],
            "allergenNote": null
          },
          "mystery_powder": {
            "compositionKnown": false,
            "allergenClasses": [],
            "dietClasses": [],
            "allergenNote": null
          }
        },
        "swaps": [
          {
            "pairId": "butter-fat-to-yogurt",
            "originalKey": "butter",
            "substituteKey": "yogurt",
            "role": "fat",
            "fits": [
              {"role": "fat", "verdict": "verified", "functionStatus": "sourced",
               "ratio": {"value": 0.75, "basis": "weight", "status": "sourced",
                         "note": null, "scales": true},
               "conditionalFor": []}
            ],
            "excludedRoles": [],
            "ratio": {"value": 0.75, "basis": "weight", "status": "sourced",
                      "note": null, "scales": true},
            "preparation": [],
            "difference": "Tangy and lighter; browns differently.",
            "sourceIds": ["S-USU"],
            "recheck": {"compositionKnown": true, "allergenClasses": ["dairy"],
                        "dietClasses": ["animal", "animal_product", "dairy_animal"],
                        "allergenNote": null}
          },
          {
            "pairId": "binder-butter-to-mystery-powder",
            "originalKey": "butter",
            "substituteKey": "mystery_powder",
            "role": "binder",
            "fits": [
              {"role": "binder", "verdict": "unknown", "functionStatus": "unknown",
               "ratio": null, "conditionalFor": []}
            ],
            "excludedRoles": [],
            "ratio": null,
            "preparation": [],
            "difference": "Completely different.",
            "sourceIds": ["S-USU"],
            "recheck": {"compositionKnown": false, "allergenClasses": [],
                        "dietClasses": [], "allergenNote": null}
          }
        ]
      }
      """
    return Data(json.utf8)
  }

  private func makeTable() throws -> SubstitutionTable {
    try SubstitutionTable(data: makeV2JSON())
  }

  // MARK: - Decode and Gate

  func testDecodesV2WithCanonicalKeys() throws {
    let table = try makeTable()
    XCTAssertEqual(table.schemaVersion, "2.0.0")
    XCTAssertEqual(table.document.swaps.count, 2)
    XCTAssertEqual(table.originalKeys, ["butter"])
    XCTAssertEqual(table.document.compositions.count, 4)
    XCTAssertNil(table.document.swaps.first?.recheck.allergenNote)
  }

  func testSchemaGateRejectsV1() throws {
    let v1 = """
      {"schemaVersion": "1.0.0", "swaps": []}
      """
    XCTAssertThrowsError(try SubstitutionTable(data: Data(v1.utf8)))
  }

  func testDeterministicDecode() throws {
    XCTAssertEqual(try makeTable().document, try makeTable().document)
  }

  // MARK: - Key-Space Lookup

  func testLookupByCanonicalKey() throws {
    let table = try makeTable()
    XCTAssertEqual(table.swaps(forCanonical: "butter").map(\.pairId).sorted(),
                   ["binder-butter-to-mystery-powder", "butter-fat-to-yogurt"])
    XCTAssertTrue(table.swaps(forCanonical: "egg").isEmpty)
    XCTAssertTrue(table.hasSwaps(forCanonical: "butter"))
    XCTAssertFalse(table.hasSwaps(forCanonical: "yogurt"))
  }

  // MARK: - Screening

  func testCompoundClosureRefusesAndNamesTheClass() throws {
    let table = try makeTable()
    let swap = table.document.swaps.first { $0.pairId == "butter-fat-to-yogurt" }!
    let outcome = table.screen(swap, restrictions: ["vegan"])
    guard case .refused(let offending) = outcome else {
      return XCTFail("expected refusal, got \(outcome)")
    }
    XCTAssertEqual(offending, ["dairy"])
  }

  func testKnownCompositionStaysAllowedWhenUnrelated() throws {
    let table = try makeTable()
    let swap = table.document.swaps.first { $0.pairId == "butter-fat-to-yogurt" }!
    if case .allowed = table.screen(swap, restrictions: ["gluten-free"]) {} else {
      XCTFail("gluten-free eaters must allow the dairy swap")
    }
  }

  func testUnknownCompositionFailsClosedToAskUser() throws {
    let table = try makeTable()
    let swap = table.document.swaps.first { $0.pairId == "binder-butter-to-mystery-powder" }!
    if case .askUser = table.screen(swap, restrictions: ["vegan"]) {} else {
      XCTFail("unknown composition must ask the user under an active restriction")
    }
  }

  func testNoRestrictionsAllowEverything() throws {
    let table = try makeTable()
    for swap in table.document.swaps {
      if case .allowed = table.screen(swap, restrictions: []) {} else {
        XCTFail("\(swap.pairId): empty restrictions must allow")
      }
    }
  }

  func testUnknownRestrictionIDsAddNoForbids() throws {
    let table = try makeTable()
    let known = table.document.swaps.first { $0.pairId == "butter-fat-to-yogurt" }!
    if case .allowed = table.screen(known, restrictions: ["keto", "low_carb"]) {} else {
      XCTFail("unknown restriction ids must add no forbids for known compositions")
    }
    let unknown = table.document.swaps.first { $0.pairId == "binder-butter-to-mystery-powder" }!
    if case .askUser = table.screen(unknown, restrictions: ["keto"]) {} else {
      XCTFail("an active dietary context keeps unknown composition fail-closed")
    }
  }

  func testAppRestrictionIDsNormalizeToTableNames() throws {
    let table = try makeTable()
    let swap = table.document.swaps.first { $0.pairId == "butter-fat-to-yogurt" }!
    // App-side id `dairy_free` normalizes to the table's `dairy-free`.
    guard case .refused(let offending) = table.screen(swap, restrictions: ["dairy_free"]) else {
      return XCTFail("expected refusal under the normalized app id")
    }
    XCTAssertEqual(offending, ["dairy"])
  }

  func testAllowedSwapsDropRefusedAndUnknownUnderRestrictions() throws {
    let table = try makeTable()
    let allowed = table.allowedSwaps(forCanonical: "butter", restrictions: ["vegan"])
    XCTAssertEqual(allowed.map(\.pairId), [])  // yogurt refuses (dairy), mystery asks
    let screened = table.screenedSwaps(forCanonical: "butter", restrictions: ["vegan"])
    XCTAssertEqual(screened.count, 2)
    XCTAssertTrue(screened.contains { entry in
      entry.swap.pairId == "butter-fat-to-yogurt" && {
        if case .refused = entry.screen { return true }
        return false
      }()
    })
    XCTAssertTrue(screened.contains { entry in
      entry.swap.pairId == "binder-butter-to-mystery-powder" && {
        if case .askUser = entry.screen { return true }
        return false
      }()
    })
  }

  // MARK: - Verdicts

  func testPrimaryVerdictPrefersThePairRole() throws {
    let table = try makeTable()
    let swap = table.document.swaps.first { $0.pairId == "butter-fat-to-yogurt" }!
    XCTAssertEqual(SubstitutionTable.primaryVerdict(of: swap), "verified")
    let unknown = table.document.swaps.first { $0.pairId == "binder-butter-to-mystery-powder" }!
    XCTAssertEqual(SubstitutionTable.primaryVerdict(of: unknown), "unknown")
  }
}
