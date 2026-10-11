import Foundation
import XCTest

@testable import ProgressFlowCheck

/// R4: on-demand provenance notes — wording is pure logic, so the source
/// labelling and aggregate policy are asserted off-host.
final class ProgressSourceNotesTests: XCTestCase {
  private func makeToday(
    source: ProgressNutritionSource,
    fallbackReason: String? = nil
  ) -> ProgressTodayReading {
    ProgressTodayReading(
      source: source,
      totals: MacroTotals(calories: 100, protein: 10, carbs: 10, fat: 10),
      fallbackReason: fallbackReason)
  }

  func testTodayNoteNamesTheSource() {
    let journal = ProgressSourceNotes.todayNote(reading: makeToday(source: .localJournal))
    XCTAssertTrue(journal.contains("your meal log"))

    let health = ProgressSourceNotes.todayNote(reading: makeToday(source: .appleHealth))
    XCTAssertTrue(health.contains("Apple Health"))
  }

  func testTodayNoteSurfacesTheFallbackInsteadOfHidingIt() {
    let note = ProgressSourceNotes.todayNote(
      reading: makeToday(source: .localJournal, fallbackReason: "Apple Health read failed: timeout"))
    XCTAssertTrue(note.contains("your meal log"))
    XCTAssertTrue(note.contains("Apple Health read failed: timeout"))
  }

  func testRangeNoteStatesTheUnknownDayPolicyAndCoverage() {
    let reading = ProgressRangeReading(
      lastDays: 7,
      source: .localJournal,
      days: [
        ProgressDayPoint(date: Date(), source: .localJournal, value: nil),
        ProgressDayPoint(
          date: Date(),
          source: .localJournal,
          value: MacroTotals(calories: 200, protein: 20, carbs: 20, fat: 20)),
      ])

    let note = ProgressSourceNotes.rangeNote(reading: reading)
    XCTAssertTrue(note.contains("last 7 days"))
    XCTAssertTrue(note.contains("not counted as zero calories"))
    XCTAssertTrue(note.contains("1 of 2 days with data"))
  }

  func testGoalNoteDistinguishesSuggestedFromConfirmed() {
    var profile = HealthProfile.default
    profile.goal = .weightLoss
    profile.dailyCalories = nil

    let suggested = ProgressSourceNotes.goalNote(
      target: .resolve(profile: profile, hasOnboarded: false))
    XCTAssertTrue(suggested.contains("Suggested target") || suggested.contains("suggested target"))
    XCTAssertTrue(suggested.contains("not one you set"))

    profile.dailyCalories = 1600
    let confirmed = ProgressSourceNotes.goalNote(
      target: .resolve(profile: profile, hasOnboarded: true))
    XCTAssertTrue(confirmed.contains("saved in your profile"))
    XCTAssertFalse(confirmed.lowercased().contains("suggested"))
  }

  /// No medical or health-advice language anywhere in the notes.
  func testNotesAvoidMedicalClaims() {
    let today = ProgressSourceNotes.todayNote(reading: makeToday(source: .localJournal))
    let range = ProgressSourceNotes.rangeNote(
      reading: ProgressRangeReading(lastDays: 7, source: .localJournal, days: []))

    let banned = ["doctor", "medical", "diet", "treatment", "you should", "healthy weight"]
    for text in [today, range] {
      for word in banned {
        XCTAssertFalse(
          text.lowercased().contains(word),
          "note must not contain advice-style language: \(word)")
      }
    }
  }
}
