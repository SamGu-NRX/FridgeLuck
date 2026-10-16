import XCTest
@testable import FLSubstitutions

/// PR #114 review round 2, fix 2: the nutrition path is role-aware. A
/// candidate asked FOR a role reports THAT role's macro delta — computed
/// from the role's own evidenced mass ratio when one exists, unknown (nil)
/// until then. The primary role's recorded delta never appears under
/// another role's name.
///
/// The reviewer's pin: egg as a binder substituted with mashed banana,
/// requested as a liquid. The liquid `supported_also` row carries no ratio
/// of its own, so the answer's nutrition is unknown — not the binder
/// ratio's number reskinned.
final class AlternativeRoleNutritionTests: XCTestCase {
    private func candidateNamed(
        _ table: SubstitutionTable, id: String,
        original: String, role: Role, restrictions: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SwapCandidate {
        let candidates = try table.swapCandidates(for: original, role: role, restrictions: restrictions)
        return try XCTUnwrap(
            candidates.first { $0.pair.id == id },
            "\(id) missing among candidates for \(original)/\(role) [\(restrictions.joined(separator: ","))]",
            file: file, line: line
        )
    }

    // MARK: 1 — the reviewer's case: egg (binder) to mashed banana, asked as a liquid

    func testEggBinderToMashedBananaRequestedAsLiquidHasUnknownNutrition() throws {
        let table = try Fixtures.table()
        let pair = try Fixtures.pair(table, id: "egg-binder-to-mashed-banana")
        // The pin's preconditions: the binder (primary) row records a real
        // delta — the number that used to leak — while the liquid row has
        // no evidenced ratio of its own.
        let binderDelta = try XCTUnwrap(pair.macroDelta, "pin precondition: the binder row records a delta")
        XCTAssertEqual(pair.ratio.basis, "weight", "pin precondition: the binder ratio is a mass statement")
        XCTAssertNil(
            pair.supportedAlso.first { $0.role == .liquid }?.ratio,
            "pin precondition: the liquid row carries no evidenced ratio"
        )

        let liquid = try candidateNamed(table, id: pair.id, original: "egg", role: .liquid, restrictions: [])
        XCTAssertNil(liquid.ratio(for: .liquid), "no evidenced liquid ratio (review finding f)")
        XCTAssertNil(
            liquid.macroDelta,
            "the liquid role's nutrition must be UNKNOWN — never the binder's delta"
        )

        // The same pair asked for a role it functionally FAILS (leavening)
        // has no evidenced amount there either: unknown, not the binder's.
        let leavening = try candidateNamed(table, id: pair.id, original: "egg", role: .leavening, restrictions: [])
        XCTAssertNil(leavening.macroDelta)

        // And the sweetener alternative — also ratio-less — stays unknown.
        let sweetener = try candidateNamed(table, id: pair.id, original: "egg", role: .sweetener, restrictions: [])
        XCTAssertNil(sweetener.macroDelta)

        // The recorded number stays bound to the role it was evidenced for.
        XCTAssertNotEqual(liquid.macroDelta, binderDelta)
    }

    // MARK: 2 — an alternative role WITH an evidenced per-role ratio

    func testAlternativeRoleWithEvidencedRatioComputesFromThatRatio() throws {
        // The shipped table has no evidenced alternative-role ratio yet
        // (every supported_also row is ratio-less), so this case builds a
        // minimal synthetic table: one pair whose `liquid` supported_also
        // row carries its OWN sourced mass ratio, distinct from the binder
        // primary's. Fixture numbers, not food claims.
        let table = try SubstitutionTable(json: Self.syntheticTableJSON())
        let pair = try Fixtures.pair(table, id: "egg-binder-to-synthetic-yogurt")
        let binderDelta = try XCTUnwrap(pair.macroDelta)

        // Primary request: the recorded delta, untouched.
        let asBinder = try candidateNamed(table, id: pair.id, original: "egg", role: .binder, restrictions: [])
        XCTAssertEqual(asBinder.macroDelta, binderDelta, "the primary path must keep the recorded delta")

        // Liquid request: computed from THE LIQUID RATIO (0.5 by weight),
        // shown as real math against the fixture's per-100 g values:
        //   substitute 50 g x 0.5 = 25 g; delta = sub(25 g) - original(50 g)
        //   kcal    100 x 25/100 - 200 x 50/100 =  -75
        //   protein 2.4 x 25/100 -  10 x 50/100 =  -4.4
        //   carbs   20  x 25/100 -   5 x 50/100 =   2.5
        //   fat     1.2 x 25/100 -  10 x 50/100 =  -4.7
        //   fiber   2   x 25/100 -   1 x 50/100 =   0.0
        //   sugar   14  x 25/100 -   2 x 50/100 =   2.5
        //   sodium  30  x 25/100 - 100 x 50/100 = -42.5
        let asLiquid = try candidateNamed(table, id: pair.id, original: "egg", role: .liquid, restrictions: [])
        let liquidDelta = try XCTUnwrap(
            asLiquid.macroDelta,
            "an evidenced liquid ratio must COMPUTE, not fall back to the binder's delta"
        )
        XCTAssertEqual(liquidDelta.kcal, -75, accuracy: 0.01)
        XCTAssertEqual(liquidDelta.proteinG, -4.4, accuracy: 0.05)
        XCTAssertEqual(liquidDelta.carbsG, 2.5, accuracy: 0.05)
        XCTAssertEqual(liquidDelta.fatG, -4.7, accuracy: 0.05)
        XCTAssertEqual(liquidDelta.fiberG, 0.0, accuracy: 0.05)
        XCTAssertEqual(liquidDelta.sugarG, 2.5, accuracy: 0.05)
        XCTAssertEqual(liquidDelta.sodiumMg, -42.5, accuracy: 0.05)

        // Distinct from the primary's — the leak is the failure mode.
        XCTAssertNotEqual(liquidDelta, binderDelta)
        XCTAssertNotEqual(asLiquid.macroDelta, asBinder.macroDelta)
    }

    // MARK: 3 — primary-role requests are byte-for-byte unchanged

    func testPrimaryRoleRequestsKeepTheRecordedDeltaAcrossTheWholeTable() throws {
        let table = try Fixtures.table()
        var checked = 0
        for pair in table.pairs {
            let candidate = try candidateNamed(
                table, id: pair.id, original: pair.original, role: pair.role, restrictions: []
            )
            XCTAssertEqual(candidate.macroDelta, pair.macroDelta, "\(pair.id): primary-role delta changed")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100, "the sweep is unexercised — candidate count collapsed")
    }

    // MARK: the dimensional and evidence discipline on the alternative path

    func testAlternativeRoleWithNonMassRatioHasUnknownNutrition() throws {
        // Review finding d on the alternative path: a quarter-cup-per-egg
        // ratio recorded for the sweetener role is kitchen-unit evidence,
        // never a gram multiplier — nutrition stays unknown.
        let table = try SubstitutionTable(json: Self.syntheticTableJSON())
        let asSweetener = try candidateNamed(
            table, id: "egg-binder-to-synthetic-yogurt", original: "egg", role: .sweetener, restrictions: []
        )
        XCTAssertNotNil(asSweetener.ratio(for: .sweetener), "the case needs a recorded non-mass ratio")
        XCTAssertNil(asSweetener.macroDelta, "a per-egg ratio must not become nutrition arithmetic")
    }

    func testAlternativeRoleWithUnsupportedAmountHasUnknownNutrition() throws {
        // An amount recorded UNSUPPORTED is not evidence to compute from —
        // nutrition stays unknown "until that role's amount has evidence".
        let table = try SubstitutionTable(json: Self.syntheticTableJSON())
        let asThickener = try candidateNamed(
            table, id: "egg-binder-to-synthetic-yogurt", original: "egg", role: .thickener, restrictions: []
        )
        XCTAssertNotNil(asThickener.ratio(for: .thickener), "the case needs a recorded (unsupported) ratio")
        XCTAssertNil(asThickener.macroDelta, "an unsupported amount is not evidence to compute from")
    }

    // MARK: the synthetic fixture

    /// One pair, three alternative rows (evidenced mass ratio, non-mass
    /// ratio, unsupported ratio), all numbers synthetic. Schema 1.1.0 shape:
    /// the 11 roles, the 9 shared classes, one fixture source.
    private static func syntheticTableJSON() -> String {
        """
        {
          "schema_version": "1.1.0",
          "created": "2026-10-12",
          "roles": ["acid", "aromatic", "binder", "fat", "garnish", "leavening", "liquid", "protein", "sweetener", "thickener", "umami"],
          "allergen_classes": ["gluten", "dairy", "egg", "soy", "peanut", "tree_nut", "sesame", "fish", "shellfish"],
          "restrictions": {},
          "sources": [
            {
              "id": "SYN-1",
              "publisher": "Synthetic fixture",
              "title": "Fixture ratios for the nutrition-path test",
              "url": "https://example.invalid/synthetic-ratio-fixture",
              "retrieved": "2026-10-12",
              "what_it_shows": "Recorded fixture amounts for a synthetic pair; not claims about food.",
              "reused_from": null
            }
          ],
          "ingredients": {
            "egg": {
              "display": "egg",
              "fdc_id": null,
              "usda_name": null,
              "macros_per_100g": {
                "kcal": 200.0, "protein_g": 10.0, "carbs_g": 5.0, "fat_g": 10.0,
                "fiber_g": 1.0, "sugar_g": 2.0, "sodium_mg": 100.0
              },
              "classes": ["animal_product", "egg"],
              "allergen_note": null,
              "aliases": [],
              "facts_key": null
            },
            "synthetic_yogurt": {
              "display": "synthetic yogurt",
              "fdc_id": null,
              "usda_name": null,
              "macros_per_100g": {
                "kcal": 100.0, "protein_g": 2.4, "carbs_g": 20.0, "fat_g": 1.2,
                "fiber_g": 2.0, "sugar_g": 14.0, "sodium_mg": 30.0
              },
              "classes": ["dairy"],
              "allergen_note": null,
              "aliases": [],
              "facts_key": null
            }
          },
          "pairs": [
            {
              "id": "egg-binder-to-synthetic-yogurt",
              "original": "egg",
              "substitute": "synthetic_yogurt",
              "role": "binder",
              "ratio": {
                "value": 1.2, "basis": "weight", "status": "sourced",
                "conflict_with": null, "note": "Fixture value."
              },
              "function_status": "sourced",
              "supported_also": [
                {
                  "role": "liquid",
                  "status": "sourced",
                  "ratio": {
                    "value": 0.5, "basis": "weight", "status": "sourced",
                    "conflict_with": null, "note": "Fixture value: the liquid role's OWN mass ratio."
                  }
                },
                {
                  "role": "sweetener",
                  "status": "convention",
                  "ratio": {
                    "value": 1.0, "basis": "quarter-cup-per-egg", "status": "convention",
                    "conflict_with": null, "note": "Fixture value: a kitchen-unit statement."
                  }
                },
                {
                  "role": "thickener",
                  "status": "unsupported",
                  "ratio": {
                    "value": 2.0, "basis": "weight", "status": "unsupported",
                    "conflict_with": null, "note": "Fixture value: the amount is recorded unsupported."
                  }
                }
              ],
              "fails": [],
              "preparation": ["Stirred smooth (synthetic fixture)."],
              "difference": "Synthetic fixture text; never promises no change.",
              "typical_amount_g": 50.0,
              "macro_delta": {
                "kcal": -40, "protein_g": -3.6, "carbs_g": 9.5, "fat_g": -4.3,
                "fiber_g": 0.7, "sugar_g": 7.4, "sodium_mg": -32.0
              },
              "macro_delta_null_reason": null,
              "source_ids": ["SYN-1"],
              "assessment": "Synthetic fixture for the round-2 nutrition-path test; not a food claim."
            }
          ]
        }
        """
    }
}
