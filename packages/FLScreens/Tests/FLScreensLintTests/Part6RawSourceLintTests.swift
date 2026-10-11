// FLScreens lint tests — Part 6 additions, in the Part 2/3/4/5 lint
// suite's conventions.
//
// Part 6 adds the Shell S alternate-shell surfaces (FLProgress's Progress
// tab and pushed Profile, FLKitchen's Shell S composition) and the two
// CANDIDATE screens (FLQuests, FLTour). The raw-source lint keeps
// scanning every Sources/ file for hex colours and font construction
// (LintTests.swift); these tests add what Part 6's screens owe:
//
// - The state files stay Foundation-only (Linux tests all of the logic);
//   every view file is Apple-gated with the unverified-native note.
// - All three candidate/entry gates ship OFF by default, in source: the
//   quests entry row (Progress), the quests candidate flag, the tour
//   candidate flag. A candidate cannot be reached by accident.
// - The share payload is an explicit allowlist: its declarations have no
//   field a pantry line, health profile, taste datum or exact time could
//   arrive in (SPEC §3.4), the way Part 5 banned safety vocab from
//   LookResult.
// - Profile carries display SIZES (host-verbatim strings), never
//   structured taste data.
// - The tour stays short and dismissible: the five-step cap in source,
//   Skip always rendered, no auto-advance timer.
// - Kitchen under Shell S is the SAME module: the composition file
//   references `KitchenView(state:` and never re-declares Kitchen's
//   title or a forked Kitchen type.
// - The saved-food counter renders through FLSavedFoodLine in BOTH
//   Progress and Quests — one grammar, they cannot drift.
// - No Part 6 view builds shell chrome of its own (tabs/docks): the
//   Part 2 shell is authoritative, Shell S is a configuration of it.
// - Every accessibility identifier uses its module's prefix from
//   docs/screens/a11y-identifiers.md.

import XCTest

final class Part6RawSourceLintTests: XCTestCase {

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
        "FLProgress/ProgressViewState.swift",
        "FLProgress/ProgressIntent.swift",
        "FLProgress/ProfileViewState.swift",
        "FLProgress/ProfileIntent.swift",
        "FLQuests/QuestsViewState.swift",
        "FLQuests/QuestsIntent.swift",
        "FLTour/TourViewState.swift",
        "FLTour/TourIntent.swift",
    ]

    private let viewFiles = [
        "FLProgress/ProgressViews.swift",
        "FLQuests/QuestsViews.swift",
        "FLTour/TourViews.swift",
        "FLKitchen/ShellSKitchenViews.swift",
    ]

    func testPart6StateFilesExistAndStayFoundationOnly() throws {
        for file in stateFiles {
            let text = try source(file)
            for banned in ["import SwiftUI", "import UIKit", "import Combine"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file) must stay Foundation-only — Linux tests all of the logic")
            }
        }
    }

    func testPart6ViewFilesAreAppleGated() throws {
        for file in viewFiles {
            let text = try source(file)
            XCTAssertTrue(text.contains("#if canImport(UIKit)"), "\(file) must be Apple-gated")
            XCTAssertTrue(text.contains("UNVERIFIED-NATIVE"), "\(file) must carry the unverified-native note")
        }
    }

    // MARK: The theme through the mapping — never a direction

    func testPart6ViewsResolveTheThemeThroughTheMappingScheme() throws {
        let densityByFile: [String: String] = [
            "FLProgress/ProgressViews.swift": "Density.dense",
            "FLQuests/QuestsViews.swift": "Density.dense",
            "FLTour/TourViews.swift": "Density.deciding",
            "FLKitchen/ShellSKitchenViews.swift": "Density.dense",
        ]
        for (file, density) in densityByFile {
            let text = try source(file)
            XCTAssertTrue(text.contains("Theme.swiftColor"), "\(file) must consume Theme colors")
            XCTAssertTrue(text.contains(".flType("), "\(file) must set type through .flType")
            XCTAssertTrue(text.contains(density), "\(file) must read \(density)")
            XCTAssertFalse(text.contains("DirectionH"), "\(file) must not name a direction")
            XCTAssertFalse(text.contains("DirectionP"), "\(file) must not name a direction")
            XCTAssertFalse(text.contains("systemGray"), "\(file) must not hard-code semantic greys")
        }
    }

    // MARK: The candidates ship off

    func testCandidateFlagsShipOffInSource() throws {
        // Three gates, all default-off in the initialisers. The entry
        // row's absence is the off state; nothing renders behind a
        // default-on candidate by accident.
        let progress = try source("FLProgress/ProgressViewState.swift")
        XCTAssertTrue(
            progress.contains("questsEnabled: Bool = false"),
            "Progress's quests entry flag must default OFF")
        XCTAssertTrue(
            progress.contains("public var showsQuestsEntry: Bool"),
            "the entry must be gated through the state's derivation, not view logic")

        let quests = try source("FLQuests/QuestsViewState.swift")
        XCTAssertTrue(
            quests.contains("enabled: Bool = false"),
            "the quests candidate must ship OFF")

        let tour = try source("FLTour/TourViewState.swift")
        XCTAssertTrue(
            tour.contains("enabled: Bool = false"),
            "the tour candidate must ship OFF")
    }

    // MARK: The share payload's allowlist (SPEC §3.4)

    func testQuestSharePayloadDeclaresOnlyTheShareableFields() throws {
        // Community cooks exclude pantry, health-profile, taste and
        // exact-time data. The payload is the ONLY value a share ever
        // builds; if someone adds an excluded field to its
        // declarations, this fails before any UI could render it.
        let text = try source("FLQuests/QuestsViewState.swift")
        let start = try XCTUnwrap(text.range(of: "public struct QuestSharePayload"), "QuestSharePayload must exist")
        let end = try XCTUnwrap(text.range(of: "public struct QuestCookRecord"), "QuestCookRecord must follow the payload")
        let payloadDecl = String(text[start.lowerBound..<end.lowerBound])
        for banned in ["pantry", "health", "taste", "embedding", "timestamp", "cookedAt", "date"] {
            XCTAssertFalse(
                payloadDecl.lowercased().contains(banned),
                "QuestSharePayload must not carry a \(banned) field — community cooks exclude it")
        }
        XCTAssertTrue(payloadDecl.contains("servings"), "the payload allows servings")
        XCTAssertTrue(payloadDecl.contains("swapsUsed"), "the payload allows swaps")
        XCTAssertTrue(payloadDecl.contains("rating"), "the payload allows the star rating")
        XCTAssertTrue(payloadDecl.contains("noteLine"), "the payload allows the one-line note")
    }

    // MARK: Profile carries sizes, never structured taste data

    func testProfileStateCarriesDisplaySizesOnly() throws {
        // The evidence rows show host-verbatim SIZE strings ("23 cooks
        // of evidence · 4 sentences learned"); the taste data itself
        // never enters this state. Same lint pattern as the payload's
        // allowlist, on ProfileViewState's stored fields.
        let text = try source("FLProgress/ProfileViewState.swift")
        let declared = text
            .split(separator: "\n")
            .filter { line in
                line.contains("public var ") || line.contains("public let ")
            }
            .joined(separator: "\n")
        XCTAssertFalse(declared.isEmpty, "the profile state must declare its fields")
        for banned in ["pantry", "health", "embedding", "vector"] {
            XCTAssertFalse(
                declared.lowercased().contains(banned),
                "ProfileViewState must not declare a \(banned) field — it carries sizes, not the data itself")
        }
    }

    // MARK: The tour stays short and dismissible

    func testTourStaysShortAndDismissible() throws {
        let state = try source("FLTour/TourViewState.swift")
        XCTAssertTrue(
            state.contains("maxSteps = 5"),
            "the five-step cap must be a named constant — the tour cannot quietly grow")
        let intent = try source("FLTour/TourIntent.swift")
        XCTAssertTrue(intent.contains("case skip"), "skip must be a first-class intent")
        let view = try source("FLTour/TourViews.swift")
        XCTAssertTrue(view.contains("fl.tour.skip"), "Skip must always be rendered and identified")
        for banned in ["Timer", "onReceive", "DispatchTimer"] {
            XCTAssertFalse(
                view.contains(banned),
                "the tour view must own no \(banned) — auto-advance is the state's decision, never a view timer")
        }
    }

    // MARK: Kitchen under Shell S is the same module

    func testShellSKitchenReusesTheKitchenModule() throws {
        let text = try source("FLKitchen/ShellSKitchenViews.swift")
        XCTAssertTrue(
            text.contains("KitchenView(state:"),
            "the Shell S composition must embed the unmodified KitchenView — no fork")
        XCTAssertFalse(
            text.contains("struct KitchenView"),
            "the composition must not re-declare KitchenView")
        XCTAssertFalse(
            text.contains("fl.kitchen.title"),
            "the composition must not render a second Kitchen title — KitchenView owns its header")
        XCTAssertTrue(
            text.contains("fl.kitchen.shellSExplore"),
            "Shell S reaches Explore from Kitchen (no Explore tab there) — the row must be identified")
    }

    // MARK: One saved-food grammar across the two counters

    func testSavedFoodCountersShareOneGrammar() throws {
        let progress = try source("FLProgress/ProgressViewState.swift")
        XCTAssertTrue(
            progress.contains("FLSavedFoodLine(grams:"),
            "Progress's saved counter renders through FLSavedFoodLine")
        let quests = try source("FLQuests/QuestsViewState.swift")
        XCTAssertTrue(
            quests.contains("FLSavedFoodLine(grams:"),
            "Quests's saved counter renders through FLSavedFoodLine — the two never drift")
    }

    // MARK: No shell chrome of their own

    func testPart6ViewsBuildNoShellChromeOfTheirOwn() throws {
        for file in viewFiles {
            let text = try source(file)
            for banned in ["TabView", "TabBar(", "tabItem"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file) must not build its own \(banned) — the Part 2 shell is authoritative, Shell S is a configuration of it")
            }
        }
    }

    // MARK: Accessibility identifiers use their module's prefixes

    func testPart6IdentifiersUseTheirModulePrefixes() throws {
        let prefixesByFile: [String: [String]] = [
            "FLProgress/ProgressViews.swift": ["fl.progress.", "fl.profile."],
            "FLQuests/QuestsViews.swift": ["fl.quests."],
            "FLTour/TourViews.swift": ["fl.tour."],
            "FLKitchen/ShellSKitchenViews.swift": ["fl.kitchen."],
        ]
        for (file, prefixes) in prefixesByFile {
            let text = try source(file)
            let identifiers = identifiersFound(in: text)
            XCTAssertFalse(identifiers.isEmpty, "\(file) must set accessibility identifiers")
            for identifier in identifiers {
                XCTAssertTrue(
                    prefixes.contains(where: { identifier.hasPrefix($0) }),
                    "\(file) identifier \(identifier) must use one of \(prefixes)")
            }
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
