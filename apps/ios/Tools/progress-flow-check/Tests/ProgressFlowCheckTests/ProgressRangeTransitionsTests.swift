import Foundation
import XCTest

@testable import ProgressFlowCheck

/// Test-side transition DSL: wraps the pure `ProgressRangeTransitions`
/// functions in an enum so tests can use implicit-member syntax.
enum RangeTransition {
  case select(ChartRange)
  case success(ProgressRangeReading, requested: ChartRange)
  case failure(ProgressReadFailure, requested: ChartRange)
  case refresh

  func applying(to state: ProgressRangeState) -> ProgressRangeState {
    switch self {
    case .select(let range):
      return ProgressRangeTransitions.select(range, from: state)
    case .success(let reading, let requested):
      return ProgressRangeTransitions.apply(.success(reading), requested: requested, to: state)
    case .failure(let failure, let requested):
      return ProgressRangeTransitions.apply(.failure(failure), requested: requested, to: state)
    case .refresh:
      return ProgressRangeTransitions.refresh(from: state)
    }
  }
}

private extension ProgressRangeState {
  func applying(_ transition: RangeTransition) -> ProgressRangeState {
    transition.applying(to: self)
  }
}

/// R2: pure range-state transitions — staleness, failure retention, source
/// labelling — plus the aggregation-policy helpers behind the day points.
final class ProgressRangeTransitionsTests: XCTestCase {
  private func reading(
    lastDays: Int = 7,
    source: ProgressNutritionSource = .localJournal,
    knownCalories: Double? = 100
  ) -> ProgressRangeReading {
    ProgressRangeReading(
      lastDays: lastDays,
      source: source,
      days: [
        ProgressDayPoint(
          date: Date(),
          source: source,
          value: knownCalories.map {
            MacroTotals(calories: $0, protein: 0, carbs: 0, fat: 0)
          })
      ])
  }

  // MARK: Transitions

  func testSelectStartsLoadAndKeepsLastGoodReadingVisible() {
    let loaded = ProgressRangeState.idle
      .applying(.select(.month))
      .applying(.success(reading(), requested: .month))
      .applying(.select(.threeMonths))

    XCTAssertEqual(loaded.selectedRange, ChartRange.threeMonths)
    XCTAssertTrue(loaded.isLoading)
    XCTAssertEqual(loaded.shown?.lastDays, 7, "the previous reading stays visible while loading")
    XCTAssertNil(loaded.errorMessage)
  }

  func testStaleResultForSupersededRangeIsDropped() {
    var state = ProgressRangeState.idle
      .applying(.select(.month))
      .applying(.success(reading(), requested: .month))

    // The user switches to .week; a straggler result for .month arrives.
    state = state.applying(.select(.week))
    state = state.applying(.success(reading(lastDays: 30), requested: .month))

    XCTAssertNotEqual(state.shown?.lastDays, 30, "a stale read must never replace the selection")
    XCTAssertTrue(state.isLoading)
    XCTAssertEqual(state.selectedRange, ChartRange.week)
  }

  func testFailureKeepsLastGoodReadingAndSurfacesError() {
    let state = ProgressRangeState.idle
      .applying(.select(.week))
      .applying(.success(reading(), requested: .week))
      .applying(.failure(.readFailed("database busy"), requested: .week))

    XCTAssertFalse(state.isLoading)
    XCTAssertEqual(state.errorMessage, "database busy")
    XCTAssertEqual(state.shown?.knownDays.count, 1, "failure must not erase the last good reading")
  }

  func testExplicitRefreshKeepsReadingAndStartsLoad() {
    let state = ProgressRangeState.idle
      .applying(.select(.week))
      .applying(.success(reading(), requested: .week))
      .applying(.refresh)

    XCTAssertTrue(state.isLoading)
    XCTAssertEqual(state.shown?.source, ProgressNutritionSource.localJournal)
    XCTAssertNil(state.errorMessage)
  }

  // MARK: Aggregation policy

  func testJournalDayPointsRestoreNoDataForUnknownDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

    // Repository output shape: zero-filled window, only yesterday nonzero.
    let journalTotals = [
      DailyMacroPoint(date: today, calories: 0, protein: 0, carbs: 0, fat: 0),
      DailyMacroPoint(date: yesterday, calories: 240, protein: 1, carbs: 2, fat: 3),
    ]

    let points = ProgressAggregation.dayPoints(
      journalTotals: journalTotals,
      knownDayKeys: [ProgressAggregation.dayKey(yesterday, calendar: calendar)],
      lastDays: 2,
      calendar: calendar)

    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points[0].value?.calories ?? 0, 240.0)
    XCTAssertNil(points[1].value, "today has no journal data: no value, not 0")
    XCTAssertTrue(points.allSatisfy { $0.source == ProgressNutritionSource.localJournal })
  }

  func testHealthDayPointsTreatAllZeroDaysAsNoData() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let today = calendar.startOfDay(for: Date())
    let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

    let healthDays = [
      AppleHealthNutritionDay(
        date: today,
        totals: AppleHealthNutritionTotals(
          calories: 500, proteinGrams: 1, carbsGrams: 2, fatGrams: 3,
          fiberGrams: 0, sugarGrams: 0, sodiumMilligrams: 0)),
      AppleHealthNutritionDay(
        date: twoDaysAgo,
        totals: AppleHealthNutritionTotals(
          calories: 0, proteinGrams: 0, carbsGrams: 0, fatGrams: 0,
          fiberGrams: 0, sugarGrams: 0, sodiumMilligrams: 0)),
    ]

    let points = ProgressAggregation.dayPoints(
      healthDays: healthDays,
      lastDays: 3,
      calendar: calendar)

    XCTAssertEqual(points.count, 3)
    XCTAssertTrue(points.allSatisfy { $0.source == ProgressNutritionSource.appleHealth })
    XCTAssertEqual(points[2].value?.calories ?? 0, 500.0, accuracy: 0.01)
    XCTAssertNil(points[0].value, "absent from the series: no data")
    XCTAssertNil(points[1].value, "all-zero samples mean no recorded data, not 0 intake")
  }

  func testWindowDatesCoversLastDaysEndingTodayOldestFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let window = ProgressAggregation.windowDates(lastDays: 7, calendar: calendar)

    XCTAssertEqual(window.count, 7)
    XCTAssertEqual(
      ProgressAggregation.dayKey(window.last!, calendar: calendar),
      ProgressAggregation.dayKey(Date(), calendar: calendar))
    XCTAssertTrue(window.first! < window.last!)
  }

  // MARK: Provenance labels

  func testGoalTargetLabelsDistinguishDefaultFromPersonal() {
    let suggested = ProgressGoalTarget(
      calories: 2000, proteinGrams: 125, carbsGrams: 225, fatGrams: 66.7,
      provenance: .suggestedTarget, goalName: "General Health")
    let confirmed = ProgressGoalTarget(
      calories: 1750, proteinGrams: 153, carbsGrams: 153, fatGrams: 58,
      provenance: .confirmedPersonalTarget, goalName: "Weight Loss")

    XCTAssertEqual(suggested.provenance.label, "Suggested target")
    XCTAssertEqual(confirmed.provenance.label, "Your target")
  }

  func testSourceDisplayNamesAreDistinct() {
    XCTAssertNotEqual(
      ProgressNutritionSource.localJournal.displayName,
      ProgressNutritionSource.appleHealth.displayName)
  }
}
