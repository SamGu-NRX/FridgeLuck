import FLFeatureLogic
import XCTest

/// Hardening tests for `AppFlowPolicy` and `ResetPolicy`.
///
/// Complements `AppFlowPolicyTests` by pinning the negative space: the
/// previously unpinned `progressEntryRoute` truth-table cell (not onboarded +
/// tutorial complete), exact-match and order semantics of the preserve filter,
/// and the duplicate/overlap behavior of the reset key lists. The duplicate
/// behaviors are harmless at the single call site (`ContentView.performFullReset`
/// passes disjoint, unique key lists and clears via idempotent
/// `UserDefaults.removeObject`), so they are pinned as-is: any change here is a
/// contract change and should be visible in review.
final class AppFlowPolicyHardeningTests: XCTestCase {
  // MARK: - progressEntryRoute

  func testProgressEntryRouteFullTruthTableCoversAllFourCells() {
    // The (hasOnboarded: false, isTutorialComplete: true) cell is not pinned by
    // AppFlowPolicyTests. A user who completed the tutorial but never finished
    // onboarding must still not reach the progress tab; a regression in the
    // guard would send them there.
    XCTAssertEqual(
      AppFlowPolicy.progressEntryRoute(hasOnboarded: false, isTutorialComplete: false),
      .emptyState
    )
    XCTAssertEqual(
      AppFlowPolicy.progressEntryRoute(hasOnboarded: false, isTutorialComplete: true),
      .emptyState
    )
    XCTAssertEqual(
      AppFlowPolicy.progressEntryRoute(hasOnboarded: true, isTutorialComplete: false),
      .emptyState
    )
    XCTAssertEqual(
      AppFlowPolicy.progressEntryRoute(hasOnboarded: true, isTutorialComplete: true),
      .progress
    )
  }

  // MARK: - Cross-entry onboarding gate consistency

  func testScanAndKitchenEntriesGateIdenticallyOnOnboarding() {
    // Both entries read the same hasOnboarded flag in the app, so for any
    // onboarding state the two gates must agree: an un-onboarded user is
    // blocked from both scan and kitchen; an onboarded user reaches both.
    for hasOnboarded in [false, true] {
      let scanAllowsEntry = AppFlowPolicy.scanEntryRoute(hasOnboarded: hasOnboarded) == .scan
      let kitchenAllowsEntry = AppFlowPolicy.kitchenEntryRoute(hasOnboarded: hasOnboarded) == .kitchen
      XCTAssertEqual(
        scanAllowsEntry,
        kitchenAllowsEntry,
        hasOnboarded ? "onboarded user" : "not-onboarded user"
      )
    }
  }

  // MARK: - tutorialKeysToClear

  func testTutorialKeysToClearPreservesRemainingKeysInInputOrder() {
    // Filter must keep relative order; a Set-based rewrite would scramble it.
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["c", "progress", "a", "b"],
      preserving: "progress"
    )
    XCTAssertEqual(keys, ["c", "a", "b"])
  }

  func testTutorialKeysToClearUsesExactMatchNotSubstring() {
    // The preserve filter compares whole keys: a key that merely contains the
    // preserved key as a substring is a distinct UserDefaults key and must
    // still be cleared.
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["progress", "progress_legacy", "legacy_progress"],
      preserving: "progress"
    )
    XCTAssertEqual(keys, ["progress_legacy", "legacy_progress"])
  }

  func testTutorialKeysToClearIsCaseSensitive() {
    // UserDefaults keys are case-sensitive; "Progress" is a different key
    // from "progress" and must be cleared.
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["progress", "Progress"],
      preserving: "progress"
    )
    XCTAssertEqual(keys, ["Progress"])
  }

  func testTutorialKeysToClearWhenPreservedKeyMissingReturnsAllKeysUnchanged() {
    // Preserving a key that is not in the list is a no-op, not a drop.
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["a", "b"],
      preserving: "missing"
    )
    XCTAssertEqual(keys, ["a", "b"])
  }

  func testTutorialKeysToClearWithEmptyKeyListReturnsEmpty() {
    XCTAssertTrue(
      ResetPolicy.tutorialKeysToClear(allKeys: [], preserving: "progress").isEmpty
    )
  }

  func testTutorialKeysToClearPassesDuplicateKeysThroughUnchanged() {
    // Pinned current behavior: the filter does not dedupe. Harmless at the
    // call site (each output key is removed with idempotent removeObject, and
    // TutorialStorageKeys.all is a literal list of unique strings), but a
    // change here is a contract change and should be visible.
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["a", "a", "progress", "a"],
      preserving: "progress"
    )
    XCTAssertEqual(keys, ["a", "a", "a"])
  }

  // MARK: - defaultsKeysToClear

  func testDefaultsKeysToClearKeepsLearningThenTutorialOrderForSingleSidedInputs() {
    XCTAssertEqual(
      ResetPolicy.defaultsKeysToClear(tutorialKeys: [], learningKeys: ["l1", "l2"]),
      ["l1", "l2"]
    )
    XCTAssertEqual(
      ResetPolicy.defaultsKeysToClear(tutorialKeys: ["t1", "t2"], learningKeys: []),
      ["t1", "t2"]
    )
  }

  func testDefaultsKeysToClearWithEmptyInputsReturnsEmpty() {
    XCTAssertTrue(
      ResetPolicy.defaultsKeysToClear(tutorialKeys: [], learningKeys: []).isEmpty
    )
  }

  func testDefaultsKeysToClearWithOverlappingKeysDuplicatesThem() {
    // Pinned current behavior: an overlap between the two input lists appears
    // once per source list. Harmless at the call site because the tutorial and
    // learning key lists are disjoint by construction (learning keys are
    // "learning_suggestions_*", tutorial keys are "tutorialProgressStorage" /
    // "hasSeen*" / "lastAdvanceSpotlightQuestShown") and duplicate removals
    // are idempotent. A change here is a contract change and should be visible.
    let keys = ResetPolicy.defaultsKeysToClear(
      tutorialKeys: ["shared", "t1"],
      learningKeys: ["shared", "l1"]
    )
    XCTAssertEqual(keys, ["shared", "l1", "shared", "t1"])
  }

  func testDefaultsKeysToClearWithProductionKeyShapesProducesNineUniqueKeys() {
    // Mirrors the real call site in ContentView.performFullReset using the
    // strings from apps/ios/Feature/Shared/TutorialStorageKeys.swift, and
    // asserts the invariants the call site relies on: exactly one entry per
    // key (no duplicates), learning keys first, and the progress key excluded.
    let allTutorialKeys: [String] = [
      "tutorialProgressStorage",
      "hasSeenSpotlightTutorial",
      "hasSeenCompletionSpotlight",
      "hasSeenReviewSpotlight",
      "hasSeenSwapTooltip",
      "hasSeenDemoSpotlight",
      "hasSeenLiveAssistantLesson",
      "lastAdvanceSpotlightQuestShown",
    ]
    let toClear = ResetPolicy.tutorialKeysToClear(
      allKeys: allTutorialKeys,
      preserving: "tutorialProgressStorage"
    )
    let keys = ResetPolicy.defaultsKeysToClear(
      tutorialKeys: toClear,
      learningKeys: ["learning_suggestions_shown", "learning_suggestions_accepted"]
    )
    XCTAssertEqual(keys.count, 9)
    XCTAssertEqual(Set(keys).count, 9)
    XCTAssertFalse(keys.contains("tutorialProgressStorage"))
    XCTAssertEqual(
      Array(keys.prefix(2)),
      ["learning_suggestions_shown", "learning_suggestions_accepted"]
    )
  }
}
