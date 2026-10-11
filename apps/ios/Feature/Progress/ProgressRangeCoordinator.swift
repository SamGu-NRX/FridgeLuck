import Foundation
import GRDB

/// Owns the Progress trend-range presentation state end to end (R2).
///
/// - Loads run as tasks: selecting a range or refreshing cancels the
///   in-flight load, and `stop()` (view closed) cancels it and stops the
///   revision observation.
/// - The revision token observation triggers an explicit refresh whenever
///   the journal or the health profile moves, so accepted portion/date
///   revisions and profile/goal edits update Progress without user action.
///   Apple Health imports do not touch these tables; the view model calls
///   `refresh()` on Health-import events and on appear.
/// - State mutation is lock-guarded rather than MainActor-isolated so the
///   off-host test suite can drive it deterministically. `onStateChange`
///   fires on whatever thread applied the change (the scheduler's queue for
///   observation-driven refreshes) — the SwiftUI view model hops to the
///   main actor when mirroring into `@Published`.
final class ProgressRangeCoordinator: @unchecked Sendable {
  var state: ProgressRangeState {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  /// Called after every state transition. Retained by the owner.
  var onStateChange: (@Sendable (ProgressRangeState) -> Void)?

  private let lock = NSLock()
  private var _state = ProgressRangeState.idle
  private let load: @Sendable (ChartRange) async throws -> ProgressRangeReading
  private let queue: (any DatabaseWriter)?
  private let observationScheduling: any ValueObservationScheduler
  private var loadTask: Task<Void, Never>?
  private var tokenCancellable: AnyDatabaseCancellable?
  private var stopped = false

  /// - Parameters:
  ///   - load: The read to run for a range. Production passes the read
  ///     model's range loader; tests pass controlled fakes.
  ///   - queue: Database to observe for revision tokens. Nil disables the
  ///     observation (state-machine-only use).
  init(
    load: @escaping @Sendable (ChartRange) async throws -> ProgressRangeReading,
    queue: (any DatabaseWriter)? = nil,
    observationScheduling: (any ValueObservationScheduler)? = nil
  ) {
    self.load = load
    self.queue = queue
    self.observationScheduling = observationScheduling ?? .mainActor
  }

  /// Production wiring: the read model's real range loader over its queue.
  static func live(readModel: ProgressReadModel, queue: any DatabaseWriter) -> ProgressRangeCoordinator {
    ProgressRangeCoordinator(
      load: { range in
        try await readModel.loadRange(lastDays: range.rawValue)
      },
      queue: queue)
  }

  /// The user picked a different range: cancel the in-flight read, keep the
  /// last good reading visible while the new one loads.
  func select(_ range: ChartRange) {
    apply(ProgressRangeTransitions.select(range, from: state))
    startLoad(range)
  }

  /// Explicit refresh: journal revision, Health import, profile change, or
  /// pull-to-refresh. Re-runs the load for the selected range.
  func refresh() {
    let range = state.selectedRange
    apply(ProgressRangeTransitions.refresh(from: state))
    startLoad(range)
  }

  /// Begins observing revision tokens. The initial token delivery triggers
  /// a refresh, so starting the observation also performs the first load
  /// for the selected range.
  func startObservation() {
    lock.lock()
    guard let queue, !stopped, tokenCancellable == nil else {
      lock.unlock()
      return
    }
    lock.unlock()

    tokenCancellable = ProgressRevisionToken.observation().start(
      in: queue,
      scheduling: observationScheduling,
      onError: { _ in
        // A failed token read leaves the last state untouched; the next
        // successful read or user action recovers. Nothing is swallowed
        // silently in tests — they observe behavior, not errors.
      },
      onChange: { [weak self] _ in
        self?.refresh()
      })
  }

  /// The view closed: cancel the in-flight load and the observation so no
  /// work continues off screen.
  func stop() {
    lock.lock()
    stopped = true
    loadTask?.cancel()
    loadTask = nil
    tokenCancellable?.cancel()
    tokenCancellable = nil
    lock.unlock()
  }

  // MARK: - Internals

  private func apply(_ next: ProgressRangeState) {
    lock.lock()
    let changed = next != _state
    _state = next
    lock.unlock()
    if changed {
      onStateChange?(next)
    }
  }

  private func startLoad(_ range: ChartRange) {
    lock.lock()
    loadTask?.cancel()
    lock.unlock()

    let task = Task<Void, Never> { [load, weak self] in
      do {
        let reading = try await load(range)
        guard !Task.isCancelled else { return }
        self?.complete(range, .success(reading))
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.complete(range, .failure(ProgressReadFailure.from(error)))
      }
    }
    lock.lock()
    loadTask = task
    lock.unlock()
  }

  private func complete(
    _ requested: ChartRange,
    _ result: Result<ProgressRangeReading, ProgressReadFailure>
  ) {
    apply(ProgressRangeTransitions.apply(result, requested: requested, to: state))
  }
}
