import Foundation

// MARK: - Overlay Transition Policy

/// Pure decision surface for the overlay's dismissal and step-navigation state machine.
/// The view owns SwiftUI state, animations, and task scheduling; this policy decides what
/// each interaction means so the Skip-versus-navigation ordering is unit-testable without
/// SwiftUI. The adapter applies the returned state verbatim: `appeared` changes animate,
/// `isPresented` changes write the binding, and a pending unmount maps to the dismiss task.
enum SpotlightOverlayStateTransitions {
  struct State: Equatable {
    var stepIndex: Int
    var appeared: Bool
    var isPresented: Bool
    /// True while a scheduled unmount has not been cancelled or completed.
    var isDismissalPending: Bool
  }

  enum Event: Equatable {
    /// Skip, or "Let's go" on the last step: fade out now, unmount after the dismiss delay.
    case dismissRequested
    /// Next or Back, with the target step index.
    case navigate(stepIndex: Int)
    /// The scheduled unmount delay elapsed without being cancelled.
    case dismissDelayElapsed
  }

  static func next(_ state: State, after event: Event, stepCount: Int) -> State {
    switch event {
    case .dismissRequested:
      var next = state
      next.appeared = false
      next.isDismissalPending = true
      return next

    case .navigate(let index):
      guard (0..<stepCount).contains(index) else { return state }
      var next = state
      next.stepIndex = index
      // Once dismissal begins the scheduled unmount runs to completion: navigation must
      // not cancel it. Cancelling here without restoring `appeared` left the overlay
      // mounted at opacity 0 (Skip → Next/Back inside the 240 ms dismiss delay) — see
      // SpotlightOverlayStateTransitionsTests.
      return next

    case .dismissDelayElapsed:
      guard state.isDismissalPending else { return state }
      var next = state
      next.isPresented = false
      next.isDismissalPending = false
      return next
    }
  }
}

// MARK: - Overlay Dismissal Adapter

/// Runtime adapter between the overlay view and the transition policy. It owns the
/// machinery the Skip-versus-navigation race lives in — the scheduled unmount task and the
/// presentation write — and routes the view's real callbacks through the policy, so the
/// callbacks, the real `Task.sleep`-based unmount, and the real binding write are
/// exercisable without SwiftUI (`SpotlightOverlayDismissalAdapterTests`). The view keeps
/// rendering: animations, the step-index transition task, and anchor scrolling.
@MainActor
final class SpotlightOverlayDismissalAdapter {
  /// Live overlay inputs and render writes, supplied fresh per event so environment reads
  /// (Reduce Motion) stay current; the scheduled unmount task keeps the wiring captured
  /// when it was scheduled, exactly as the view task it replaces did.
  struct Wiring {
    let stepCount: Int
    let currentAppeared: () -> Bool
    let setAppeared: (Bool) -> Void
    let currentPresented: () -> Bool
    let setPresented: (Bool) -> Void
  }

  private let dismissDelay: Duration
  private var dismissTask: Task<Void, Never>?
  /// The step index the policy last accepted; the view's rendered index mirrors it.
  private(set) var acceptedStepIndex = 0

  init(dismissDelay: Duration = .milliseconds(240)) {
    self.dismissDelay = dismissDelay
  }

  /// Skip, or "Let's go" on the last step: fade out now, unmount after the delay.
  func dismissRequested(_ wiring: Wiring) {
    apply(.dismissRequested, wiring)
  }

  /// Next or Back. Returns the accepted policy outcome for the view's step transition, or
  /// nil when the index falls outside the tour's range.
  @discardableResult
  func navigationRequested(
    to index: Int,
    _ wiring: Wiring
  ) -> SpotlightOverlayStateTransitions.State? {
    guard (0..<wiring.stepCount).contains(index) else { return nil }
    // Pre-fix view wiring, ported verbatim: navigation cancelled the scheduled unmount
    // without restoring `appeared`, leaving the overlay mounted at opacity 0. Kept on
    // this commit so the adapter regression records that failure on hosted CI; the next
    // commit removes the cancellation.
    dismissTask?.cancel()
    return apply(.navigate(stepIndex: index), wiring)
  }

  /// Cancels the pending unmount (view teardown or a restarted tour presentation).
  func cancelPendingUnmount() {
    dismissTask?.cancel()
    dismissTask = nil
  }

  /// A restarted tour (new presentation ID) begins from step 0 again.
  func resetForNewPresentation() {
    cancelPendingUnmount()
    acceptedStepIndex = 0
  }

  @discardableResult
  private func apply(
    _ event: SpotlightOverlayStateTransitions.Event,
    _ wiring: Wiring
  ) -> SpotlightOverlayStateTransitions.State {
    let snapshot = SpotlightOverlayStateTransitions.State(
      stepIndex: acceptedStepIndex,
      appeared: wiring.currentAppeared(),
      isPresented: wiring.currentPresented(),
      isDismissalPending: dismissTask != nil
    )
    let outcome = SpotlightOverlayStateTransitions.next(
      snapshot,
      after: event,
      stepCount: wiring.stepCount
    )

    if outcome.appeared != snapshot.appeared {
      wiring.setAppeared(outcome.appeared)
    }
    if outcome.isPresented != snapshot.isPresented {
      wiring.setPresented(outcome.isPresented)
    }
    if outcome.isDismissalPending {
      if dismissTask == nil {
        scheduleUnmount(wiring)
      }
    } else {
      dismissTask?.cancel()
      dismissTask = nil
    }
    acceptedStepIndex = outcome.stepIndex

    return outcome
  }

  private func scheduleUnmount(_ wiring: Wiring) {
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: self.dismissDelay)
      guard !Task.isCancelled else { return }
      self.apply(.dismissDelayElapsed, wiring)
    }
  }
}
