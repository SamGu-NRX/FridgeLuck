// FLScreens lint tests — Part 5 additions, in the Part 2/3/4 lint suite's
// conventions.
//
// Part 5 adds FLLeChef, the cook mode. The raw-source lint keeps scanning
// every Sources/ file for hex colours and font construction
// (LintTests.swift); these tests add what Part 5's screen owes:
//
// - The state files stay Foundation-only (Linux tests all of the logic);
//   the view file is Apple-gated with the unverified-native note.
// - The cook surface resolves the theme through the cook palette —
//   Theme.swiftColor in the .hob scheme, which FLRenderPaletteMapping
//   resolves from whichever direction theme is configured. The file never
//   names a direction and never reads the ambient scheme: a cook-mode
//   object does not recolour.
// - No photos on this surface: nothing touches PhotoLayoutRule — the
//   look preview is the host's live camera surface, not a photo asset.
// - The camera-candidate rule is visible in source: push-to-look is the
//   built candidate; continuous camera + voice is flagged, not built.
// - A look can never yield a safety verdict: LookResult declares no
//   doneness/safety/verdict field, and no safety-claim wording appears in
//   the look result type's declarations.
// - The persisted snapshot declares no frame, transcript or look field.
// - Voice is opt-in with "Just the steps" as the named default.
// - LeChef is not a tab: the view builds no tab hierarchy and no dock.
// - Every accessibility identifier the views set uses the fl.lechef.
//   prefix from docs/screens/a11y-identifiers.md.

import XCTest

final class Part5RawSourceLintTests: XCTestCase {

    // MARK: Locating the sources (from #filePath — no cwd assumptions)

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relative: String) throws -> String {
        let url = packageRoot.appendingPathComponent("Sources").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Existence and gating

    private let stateFiles = [
        "FLLeChef/LeChefViewState.swift",
        "FLLeChef/LeChefPersistedState.swift",
        "FLLeChef/LeChefIntent.swift",
    ]

    func testLeChefStateFilesExistAndStayFoundationOnly() throws {
        for file in stateFiles {
            let text = try source(file)
            for banned in ["import SwiftUI", "import UIKit", "import Combine"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file) must stay Foundation-only — Linux tests all of the logic")
            }
        }
    }

    func testLeChefViewFileIsAppleGated() throws {
        let text = try source("FLLeChef/LeChefViews.swift")
        XCTAssertTrue(text.contains("#if canImport(UIKit)"), "the view file must be Apple-gated")
        XCTAssertTrue(text.contains("UNVERIFIED-NATIVE"), "the view file must carry the unverified-native note")
    }

    // MARK: The cook palette through the mapping — never a direction

    func testLeChefViewResolvesTheCookPaletteThroughTheTheme() throws {
        let text = try source("FLLeChef/LeChefViews.swift")
        XCTAssertTrue(text.contains("Theme.swiftColor"), "the surface must consume Theme colors")
        XCTAssertTrue(text.contains("in: .hob"), "the cook surface pins the cook palette (.hob)")
        XCTAssertTrue(text.contains(".flType("), "the surface must set type through .flType")
        XCTAssertTrue(text.contains("Density.deciding"), "cook-mode step and complete are generous-density surfaces")
        XCTAssertFalse(text.contains("DirectionH"), "the surface must not name a direction")
        XCTAssertFalse(text.contains("DirectionP"), "the surface must not name a direction")
        XCTAssertFalse(text.contains("systemGray"), "the surface must not hard-code semantic greys")
    }

    // MARK: No photos on the cook surface

    func testLeChefSurfaceShowsNoPhotoAssets() throws {
        let text = try source("FLLeChef/LeChefViews.swift")
        XCTAssertFalse(
            text.contains("PhotoLayoutRule"),
            "the cook surface shows no photos — a rule here means someone drew one")
    }

    // MARK: The camera candidates, as source

    func testPushToLookIsTheBuiltCandidateAndContinuousIsFlaggedOnly() throws {
        let text = try source("FLLeChef/LeChefViewState.swift")
        XCTAssertTrue(text.contains("case pushToLook"))
        XCTAssertTrue(text.contains("case continuousVoice"), "the competing candidate must exist to be scored")
        XCTAssertTrue(
            text.contains("maxClipSeconds = 3"),
            "the three-second clip cap must be a named constant")
    }

    func testTheLookResultDeclaresNoSafetyVerdictField() throws {
        // A look NEVER yields a safety verdict: the result type has no
        // field for one. If someone adds `safety` to LookResult, this
        // fails before any UI can render a claim from it.
        let text = try source("FLLeChef/LeChefViewState.swift")
        let start = try XCTUnwrap(text.range(of: "public struct LookResult"), "LookResult must exist")
        let end = try XCTUnwrap(text.range(of: "// MARK: Transcript"))
        let lookResultDecl = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(lookResultDecl.contains("observedLines"), "a look observes")
        for banned in ["safety", "doneness", "verdict", "temperature", "isSafe", "safe"] {
            XCTAssertFalse(
                lookResultDecl.lowercased().contains(banned.lowercased()),
                "LookResult must not carry a \(banned) field — a look's claims have nowhere to arrive from")
        }
        let view = try source("FLLeChef/LeChefViews.swift")
        XCTAssertTrue(
            view.contains("proposalDisplay(proposal)"),
            "look results render only through the shared display grammar — the state pairs every result with what it cannot assess, and the view must not bypass it")
    }

    // MARK: The persisted snapshot's allowlist

    func testThePersistedSnapshotDeclaresNoTransientField() throws {
        // No frame, no transcript, no look result beyond the live
        // session — by construction, in the DECLARATIONS. Prose may
        // explain the absence; the field list may not grow one. The
        // exact allowlist is also pinned by the Mirror walk in
        // LeChefPersistenceTests.
        let text = try source("FLLeChef/LeChefPersistedState.swift")
        let declared = text
            .split(separator: "\n")
            .filter { line in
                line.contains("public var ") || line.contains("public let ")
            }
            .joined(separator: "\n")
        XCTAssertFalse(declared.isEmpty, "the snapshot must declare its fields")
        for banned in ["frame", "transcript", "look", "imageData", "photo"] {
            XCTAssertFalse(
                declared.lowercased().contains(banned),
                "the persisted snapshot must not declare a \(banned) field")
        }
    }

    // MARK: Voice opt-in, "Just the steps" default

    func testVoiceIsOptInWithTheStepsDefault() throws {
        let state = try source("FLLeChef/LeChefViewState.swift")
        XCTAssertTrue(
            state.contains("isTranscriptOn: Bool = false"),
            "the state's default is Just the steps")
        XCTAssertTrue(
            state.contains("Just the steps"),
            "the surface's name for the default is 'Just the steps'")
        let reducer = try source("FLLeChef/LeChefIntent.swift")
        XCTAssertTrue(
            reducer.contains("guard next.isTranscriptOn else { break }"),
            "voice commands only work behind the opt-in")
    }

    // MARK: Not a tab — a presented mode

    func testLeChefBuildsNoTabHierarchyOfItsOwn() throws {
        let text = try source("FLLeChef/LeChefViews.swift")
        for banned in ["TabView", "TabBar", "tabItem"] {
            XCTAssertFalse(
                text.contains(banned),
                "LeChef must not build its own \(banned) — it is a mode, presented, not a tab")
        }
        XCTAssertTrue(
            text.contains("FLDesignSystem"),
            "LeChef must consume the shared design-system surface")
    }

    // MARK: Accessibility identifiers use the fl.lechef. prefix

    func testLeChefIdentifiersUseTheLeChefPrefix() throws {
        let text = try source("FLLeChef/LeChefViews.swift")
        let identifiers = identifiersFound(in: text)
        XCTAssertFalse(identifiers.isEmpty, "LeChefViews must set accessibility identifiers")
        for identifier in identifiers {
            XCTAssertTrue(
                identifier.hasPrefix("fl.lechef."),
                "LeChefViews identifier \(identifier) must use the fl.lechef. prefix")
        }
    }

    /// Pulls every string literal that looks like a namespaced identifier.
    private func identifiersFound(in text: String) -> [String] {
        let pattern = #"fl\.[a-z]+(?:\.[A-Za-z0-9]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
