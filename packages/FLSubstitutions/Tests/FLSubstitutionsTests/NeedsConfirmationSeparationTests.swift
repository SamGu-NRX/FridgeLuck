import XCTest
@testable import FLSubstitutions

/// PR #114 review round 2, fix 1: a candidate that needs confirmation is
/// never a usable swap. The lookup separates verdicts into usable swaps,
/// needs-confirmation questions, and the refused remainder — and ONLY
/// candidates with no confirmation requirement land in usable. A swap whose
/// replacement is known-safe may still remove a known violation in the
/// original.
final class NeedsConfirmationSeparationTests: XCTestCase {
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

    // MARK: the reviewer's case — only the ORIGINAL's composition unknown

    func testButtermilkToWholeMilkUnderVegetarianNeedsConfirmationAndIsNeverUsable() throws {
        let table = try Fixtures.table()
        // The canonical case: buttermilk has no facts record (composition
        // unknown), whole milk resolves to the reviewed `milk` record, and
        // vegetarian eaters allow dairy. The swap used to come back as a
        // verified, usable swap on the strength of the substitute alone.
        let candidate = try candidateNamed(
            table, id: "buttermilk-liquid-to-whole-milk",
            original: "buttermilk", role: .liquid, restrictions: ["vegetarian"]
        )
        XCTAssertTrue(
            candidate.needsConfirmation,
            "the original's unknown composition must require confirmation"
        )
        XCTAssertFalse(candidate.isRefused, "the substitute is known-safe; nothing is refused")
        XCTAssertEqual(
            candidate.verdict, .verified,
            "the context evidence is verified — the composition question is what withholds the offer"
        )
        guard case .askUser(let originalReasons) = candidate.recheck.originalOutcome else {
            return XCTFail("expected ask-user on the ORIGINAL side, got \(candidate.recheck.originalOutcome)")
        }
        XCTAssertTrue(
            originalReasons.contains { $0.lowercased().contains("buttermilk") },
            "the question must name the original: \(originalReasons)"
        )
        XCTAssertEqual(candidate.recheck.outcome, .allowed, "the replacement is known-safe")

        // Never in the usable result — neither the offer list nor the bucket.
        let offered = try table.swaps(for: "buttermilk", role: .liquid, restrictions: ["vegetarian"])
        XCTAssertFalse(
            offered.contains { $0.pair.id == "buttermilk-liquid-to-whole-milk" },
            "buttermilk to whole milk offered while the original's composition is unknown"
        )
        let classified = try table.classifiedSwaps(for: "buttermilk", role: .liquid, restrictions: ["vegetarian"])
        XCTAssertFalse(classified.usable.contains { $0.pair.id == "buttermilk-liquid-to-whole-milk" })
        XCTAssertTrue(
            classified.needsConfirmation.contains { $0.pair.id == "buttermilk-liquid-to-whole-milk" },
            "the swap must surface as a needs-confirmation question"
        )
        XCTAssertFalse(classified.refused.contains { $0.pair.id == "buttermilk-liquid-to-whole-milk" })
    }

    // MARK: the preserved property — removing a known violation

    func testKnownViolationOriginalWithKnownSafeSubstituteStaysUsable() throws {
        let table = try Fixtures.table()
        // Butter is a settled vegan violation; olive oil is reviewed and
        // known-safe. Removing the violation is the point of the swap — the
        // new needs-confirmation bucket must not swallow this case.
        let candidate = try candidateNamed(
            table, id: "butter-fat-to-olive-oil",
            original: "butter", role: .fat, restrictions: ["vegan"]
        )
        XCTAssertFalse(candidate.needsConfirmation, "a settled original violation is not a composition question")
        XCTAssertFalse(candidate.isRefused)
        XCTAssertEqual(candidate.verdict, .verified)
        guard case .violated(let reason) = candidate.recheck.originalOutcome else {
            return XCTFail("expected a settled violation on the original, got \(candidate.recheck.originalOutcome)")
        }
        XCTAssertTrue(
            reason.lowercased().contains("butter"),
            "the violation must name the original: \(reason)"
        )
        XCTAssertEqual(candidate.recheck.outcome, .allowed)
        XCTAssertTrue(candidate.recheck.removed.contains(.dairy), "the swap removes the dairy class")
        XCTAssertTrue(candidate.recheck.removed.contains(.animalProduct))

        let offered = try table.swaps(for: "butter", role: .fat, restrictions: ["vegan"])
        XCTAssertTrue(
            offered.contains { $0.pair.id == "butter-fat-to-olive-oil" },
            "a known violation removed by a known-safe replacement must stay usable"
        )
        let classified = try table.classifiedSwaps(for: "butter", role: .fat, restrictions: ["vegan"])
        XCTAssertTrue(classified.usable.contains { $0.pair.id == "butter-fat-to-olive-oil" })
        XCTAssertFalse(classified.needsConfirmation.contains { $0.pair.id == "butter-fat-to-olive-oil" })
        XCTAssertFalse(classified.refused.contains { $0.pair.id == "butter-fat-to-olive-oil" })
    }

    // MARK: substitute-side unknown stays a question

    func testSubstituteUnknownCompositionSurfacesInTheNeedsConfirmationBucket() throws {
        let table = try Fixtures.table()
        // Generic tamari for a gluten-free eater: the SUBSTITUTE's
        // composition is unknown. Unknown is a question, not a settled no —
        // the certified product form exists — so the classified result must
        // surface it in needs-confirmation, never in usable.
        let candidate = try candidateNamed(
            table, id: "soy-sauce-umami-to-tamari",
            original: "soy sauce", role: .umami, restrictions: ["gluten-free"]
        )
        XCTAssertTrue(candidate.needsConfirmation)
        XCTAssertTrue(candidate.isRefused, "unconfirmed composition is not offerable either way")
        guard case .askUser = candidate.recheck.outcome else {
            return XCTFail("expected ask-user on the substitute side, got \(candidate.recheck.outcome)")
        }

        let classified = try table.classifiedSwaps(for: "soy sauce", role: .umami, restrictions: ["gluten-free"])
        XCTAssertFalse(classified.usable.contains { $0.pair.id == "soy-sauce-umami-to-tamari" })
        XCTAssertTrue(
            classified.needsConfirmation.contains { $0.pair.id == "soy-sauce-umami-to-tamari" },
            "the ask-user path must survive the classification"
        )
        XCTAssertFalse(classified.refused.contains { $0.pair.id == "soy-sauce-umami-to-tamari" })
    }

    // MARK: a moot question must not shadow a settled refusal

    func testOriginalUnknownWithSettledSubstituteViolationIsRefusedNotAQuestion() throws {
        let table = try Fixtures.table()
        // Buttermilk (composition unknown) to plain yogurt under vegan: the
        // original needs confirmation, but the substitute is a SETTLED
        // violation — no question can make it offerable. The candidate keeps
        // its needs-confirmation flag for inspection; the classified result
        // refuses it instead of showing a moot question.
        let candidate = try candidateNamed(
            table, id: "buttermilk-liquid-to-plain-yogurt",
            original: "buttermilk", role: .liquid, restrictions: ["vegan"]
        )
        XCTAssertTrue(candidate.needsConfirmation, "the original's composition is still unknown")
        XCTAssertTrue(candidate.isRefused, "the settled substitute violation refuses the swap")
        guard case .violated(let reason) = candidate.recheck.outcome else {
            return XCTFail("expected a settled substitute violation, got \(candidate.recheck.outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("yogurt"), "the refusal must name the substitute: \(reason)")

        let classified = try table.classifiedSwaps(for: "buttermilk", role: .liquid, restrictions: ["vegan"])
        XCTAssertFalse(classified.usable.contains { $0.pair.id == "buttermilk-liquid-to-plain-yogurt" })
        XCTAssertFalse(
            classified.needsConfirmation.contains { $0.pair.id == "buttermilk-liquid-to-plain-yogurt" },
            "a moot question must not shadow the settled refusal"
        )
        XCTAssertTrue(classified.refused.contains { $0.pair.id == "buttermilk-liquid-to-plain-yogurt" })
    }

    // MARK: no invented questions without restrictions

    func testUnrestrictedLookupsAreNeverAskedToConfirmComposition() throws {
        let table = try Fixtures.table()
        // With no restrictions there is nothing to screen: the store is not
        // consulted and no safety question is invented; the verified swap
        // stays usable (AllergySweepTests pins the no-refusal side).
        let classified = try table.classifiedSwaps(for: "buttermilk", role: .liquid, restrictions: [])
        XCTAssertTrue(classified.needsConfirmation.isEmpty, "no invented questions for an unrestricted eater")
        XCTAssertTrue(classified.usable.contains { $0.pair.id == "buttermilk-liquid-to-whole-milk" })
    }

    // MARK: the contract holds across the whole lookup battery

    func testSwapsEqualTheUsableBucketAndBucketsPartitionCandidatesEverywhere() throws {
        let table = try Fixtures.table()
        for restrictions in Fixtures.restrictionBatteries {
            let label = restrictions.joined(separator: ",")
            for name in Fixtures.lookupBattery(table) {
                for role in Role.allCases {
                    let candidates = try table.swapCandidates(for: name, role: role, restrictions: restrictions)
                    let classified = try table.classifiedSwaps(for: name, role: role, restrictions: restrictions)
                    let offered = try table.swaps(for: name, role: role, restrictions: restrictions)

                    // swaps IS the usable bucket, in the same order.
                    XCTAssertEqual(
                        offered.map { $0.pair.id }, classified.usable.map { $0.pair.id },
                        "\(name)/\(role) [\(label)]: swaps must be the usable bucket"
                    )

                    // The buckets are disjoint and complete, and each keeps
                    // the candidates' deterministic rank order.
                    let candidateIds = candidates.map { $0.pair.id }
                    let buckets = [classified.usable, classified.needsConfirmation, classified.refused]
                    let concatenated = buckets.flatMap { $0.map { $0.pair.id } }
                    XCTAssertEqual(
                        concatenated.count, candidateIds.count,
                        "\(name)/\(role) [\(label)]: a candidate landed in two buckets"
                    )
                    XCTAssertEqual(
                        Set(concatenated), Set(candidateIds),
                        "\(name)/\(role) [\(label)]: buckets must partition the candidates"
                    )
                    for bucket in buckets {
                        let bucketIds = bucket.map { $0.pair.id }
                        XCTAssertEqual(
                            bucketIds, candidateIds.filter { bucketIds.contains($0) },
                            "\(name)/\(role) [\(label)]: a bucket broke the candidates' rank order"
                        )
                    }

                    // The contract: nothing needing confirmation is usable.
                    for candidate in classified.usable {
                        XCTAssertFalse(
                            candidate.needsConfirmation,
                            "\(candidate.pair.id) [\(label)]: needs confirmation yet usable"
                        )
                        XCTAssertFalse(
                            candidate.isRefused,
                            "\(candidate.pair.id) [\(label)]: refused yet usable"
                        )
                    }
                }
            }
        }
    }
}
