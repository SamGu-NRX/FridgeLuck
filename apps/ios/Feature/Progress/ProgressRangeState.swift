import Foundation

// MARK: - Range

/// Trend-chart range. Moved from the view model file so the range state
/// machine below stays UI-free and testable off-host. Values are day counts.
enum ChartRange: Int, CaseIterable, Identifiable, Sendable {
  case week = 7
  case month = 30
  case threeMonths = 90

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .week: "7D"
    case .month: "30D"
    case .threeMonths: "90D"
    }
  }

  var sectionTitle: String {
    switch self {
    case .week: "This Week"
    case .month: "Last 30 Days"
    case .threeMonths: "Last 90 Days"
    }
  }
}

// MARK: - Range state

/// Presentation state for the selected trend range, owned by the Progress
/// feature. Invariants (asserted by ProgressRangeTransitionsTests):
///
/// - a result for a range other than the selected one is dropped — stale
///   reads from superseded or cancelled requests never render;
/// - a failure never erases the last good reading; it surfaces alongside it;
/// - whatever is shown carries its own source label from the reading itself,
///   so a source switch is visible and sources are never blended.
struct ProgressRangeState: Equatable, Sendable {
  let selectedRange: ChartRange
  /// The last good reading, kept visible across loads and failures.
  let shown: ProgressRangeReading?
  let isLoading: Bool
  let errorMessage: String?

  static let idle = ProgressRangeState(
    selectedRange: .week, shown: nil, isLoading: false, errorMessage: nil)
}

/// Pure transitions over `ProgressRangeState`. The view model applies these
/// after cancelling in-flight reads; cancellation semantics live with the
/// tasks, staleness semantics here.
enum ProgressRangeTransitions {
  /// The user picked a different range: start a load, keep the last good
  /// reading visible, clear any previous error.
  static func select(_ range: ChartRange, from state: ProgressRangeState) -> ProgressRangeState {
    ProgressRangeState(
      selectedRange: range,
      shown: state.shown,
      isLoading: true,
      errorMessage: nil)
  }

  /// A read finished for `requested`. Results for a superseded range are
  /// dropped so stale data never replaces the selected range's state.
  static func apply(
    _ result: Result<ProgressRangeReading, ProgressReadFailure>,
    requested: ChartRange,
    to state: ProgressRangeState
  ) -> ProgressRangeState {
    guard requested == state.selectedRange else { return state }

    switch result {
    case .success(let reading):
      return ProgressRangeState(
        selectedRange: state.selectedRange,
        shown: reading,
        isLoading: false,
        errorMessage: nil)
    case .failure(let failure):
      return ProgressRangeState(
        selectedRange: state.selectedRange,
        shown: state.shown,
        isLoading: false,
        errorMessage: failure.message)
    }
  }

  /// An explicit refresh (journal revision, Health import, profile change,
  /// or pull-to-refresh): re-run the load, keep the last good reading shown.
  static func refresh(from state: ProgressRangeState) -> ProgressRangeState {
    ProgressRangeState(
      selectedRange: state.selectedRange,
      shown: state.shown,
      isLoading: true,
      errorMessage: nil)
  }
}

/// Failure value carried through the range state. The view model maps thrown
/// errors into this so the state stays Equatable and Sendable.
enum ProgressReadFailure: Equatable, Sendable, Error {
  case readFailed(String)

  var message: String {
    switch self {
    case .readFailed(let message): message
    }
  }

  /// Wraps a thrown error without double-wrapping our own kind, so the
  /// surfaced message stays readable.
  static func from(_ error: Error) -> ProgressReadFailure {
    (error as? ProgressReadFailure) ?? .readFailed(String(describing: error))
  }
}
