import SwiftUI
import XCTest

@testable import FridgeLuck

/// Behavioral coverage for the settings slice of the design system:
/// `FLSettingsSummaryCard`, `FLSettingsBadge`, `FLStreakBadge`, and the
/// shared bottom-bar clearance contract in `FLSettingsComponents`.
@MainActor
final class DS10SettingsTests: XCTestCase {

  // MARK: - FLSettingsSummaryCard.initial

  func testInitialUsesFirstGraphemeOfPlainName() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "Alice", subtitle: "").initial, "A")
  }

  func testInitialUppercasesLowercaseName() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "alice", subtitle: "").initial, "A")
  }

  func testInitialSkipsLeadingWhitespace() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "   Alice", subtitle: "").initial, "A")
  }

  func testInitialTrimsWhitespaceAndNewlinesOnBothSides() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "\n\t Bob \n\t", subtitle: "").initial, "B")
  }

  func testInitialOfEmptyNameIsEmpty() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "", subtitle: "").initial, "")
  }

  func testInitialOfWhitespaceOnlyNameIsEmpty() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "   ", subtitle: "").initial, "")
  }

  func testInitialKeepsEmojiGraphemeIntact() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "🦊 fox", subtitle: "").initial, "🦊")
  }

  func testInitialKeepsMultiScalarEmojiGraphemeIntact() {
    // Family emoji spans several Unicode scalars but is one grapheme cluster.
    XCTAssertEqual(FLSettingsSummaryCard(title: "👨‍👩‍👧‍👦 fam", subtitle: "").initial, "👨‍👩‍👧‍👦")
  }

  func testInitialKeepsCJKGraphemeIntact() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "田中さん", subtitle: "").initial, "田")
  }

  func testInitialCollapsesCombiningMarksIntoOneGrapheme() {
    // "e" + U+0301 combining acute must surface as one accented grapheme, not "e".
    XCTAssertEqual(FLSettingsSummaryCard(title: "e\u{0301}clair", subtitle: "").initial, "É")
  }

  func testInitialOfDigitLeadingNameUsesDigit() {
    XCTAssertEqual(FLSettingsSummaryCard(title: "4 you", subtitle: "").initial, "4")
  }

  // MARK: - FLSettingsBadge identity & hash

  func testBadgeExplicitIDOverridesDerivedID() {
    let badge = FLSettingsBadge(id: "custom", text: "Allowed", tone: .positive)
    XCTAssertEqual(badge.id, "custom")
  }

  func testBadgeDistinctTextsProduceDistinctDefaultIDs() {
    let allowed = FLSettingsBadge(text: "Allowed", tone: .positive)
    let denied = FLSettingsBadge(text: "Denied", tone: .positive)
    XCTAssertNotEqual(allowed.id, denied.id)
  }

  func testBadgeDistinctTonesProduceDistinctDefaultIDs() {
    let accent = FLSettingsBadge(text: "Limited", tone: .accent)
    let neutral = FLSettingsBadge(text: "Limited", tone: .neutral)
    XCTAssertNotEqual(accent.id, neutral.id)
  }

  func testBadgeExplicitIDsDifferentiateIdenticalContent() {
    // Two badges with the same text and tone collide on the derived default id;
    // explicit ids are the caller's escape hatch for ForEach identity.
    let first = FLSettingsBadge(id: "a", text: "Local", tone: .neutral)
    let second = FLSettingsBadge(id: "b", text: "Local", tone: .neutral)
    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(first.id, second.id)
  }

  func testBadgeEqualityAndHashAgree() {
    let derived = FLSettingsBadge(text: "Allowed", tone: .positive)
    let explicit = FLSettingsBadge(id: "Allowed-positive", text: "Allowed", tone: .positive)
    XCTAssertEqual(derived, explicit)
    XCTAssertEqual(derived.hashValue, explicit.hashValue)
  }

  func testBadgeSetDeduplicatesEqualBadges() {
    let badges: Set = [
      FLSettingsBadge(text: "Allowed", tone: .positive),
      FLSettingsBadge(id: "Allowed-positive", text: "Allowed", tone: .positive),
      FLSettingsBadge(text: "Denied", tone: .warning),
    ]
    XCTAssertEqual(badges.count, 2)
  }

  // MARK: - FLStreakBadge

  func testMilestoneThresholdsMatchPublishedMilestones() {
    XCTAssertEqual(FLStreakBadge.milestoneThresholds, Set([7, 14, 30, 60, 100]))
  }

  func testMilestoneThresholdsDetectBoundaries() {
    XCTAssertTrue(FLStreakBadge.milestoneThresholds.contains(7))
    XCTAssertTrue(FLStreakBadge.milestoneThresholds.contains(100))
    XCTAssertFalse(FLStreakBadge.milestoneThresholds.contains(6))
    XCTAssertFalse(FLStreakBadge.milestoneThresholds.contains(101))
  }

  func testDayLabelsAreMondayFirstToMatchProducers() {
    // PersonalizationService.weekActivity() and HomeDashboardView both index
    // day 0 as Monday; the captions must align or every dot reads as the
    // previous weekday.
    XCTAssertEqual(FLStreakBadge.dayLabels, ["M", "T", "W", "T", "F", "S", "S"])
    XCTAssertEqual(FLStreakBadge.dayLabels.count, 7)
  }

  func testAccessibilitySummaryCountsFullWeek() {
    let week = [true, false, true, false, true, false, true]
    XCTAssertEqual(
      FLStreakBadge.accessibilitySummary(currentStreak: 4, weekActivity: week),
      "4 day streak, 4 of 7 days active this week")
  }

  func testAccessibilitySummaryWithNoActiveDays() {
    XCTAssertEqual(
      FLStreakBadge.accessibilitySummary(
        currentStreak: 0, weekActivity: Array(repeating: false, count: 7)),
      "0 day streak, 0 of 7 days active this week")
  }

  func testAccessibilitySummaryIgnoresActiveDaysBeyondDisplayedWeek() {
    // The badge renders at most 7 dots; the label must not claim more active
    // days than are shown ("8 of 7" is impossible).
    XCTAssertEqual(
      FLStreakBadge.accessibilitySummary(
        currentStreak: 8, weekActivity: Array(repeating: true, count: 8)),
      "8 day streak, 7 of 7 days active this week")
  }

  func testAccessibilitySummaryIgnoresInactiveDaysBeyondDisplayedWeek() {
    // Days past the displayed window must not leak into the active count.
    let nineIdlePlusOneActive = Array(repeating: false, count: 9) + [true]
    XCTAssertEqual(
      FLStreakBadge.accessibilitySummary(
        currentStreak: 1, weekActivity: nineIdlePlusOneActive),
      "1 day streak, 0 of 7 days active this week")
  }

  // MARK: - Bottom bar / clearance consistency

  func testBottomClearanceConstantIsPinnedForBarAndClearanceModifiers() {
    // Both flSettingsBottomActionBar and flSettingsBottomClearance reserve this
    // same shared constant; if it drifts, content hides behind the bar.
    XCTAssertEqual(AppTheme.Space.bottomClearance, 100)
    XCTAssertGreaterThan(AppTheme.Space.bottomClearance, AppTheme.Space.lg)
  }
}
