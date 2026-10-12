// FLTour — the tour candidate's typed intents and reducer.
//
// The reducer owns the machine's edges the mock's notes state: skip is
// always available and final for the session, back never goes before
// the first step, completing the last promise completes the tour, and
// a finished tour cannot re-arm. Every transition is host-observed —
// the stage is a value the host renders or reacts to.

import Foundation

/// Everything the tour can send.
public enum TourIntent: Equatable, Sendable {

    /// The host supplies the promises (verbatim, in order).
    case stepsArrived([TourViewState.Step])
    /// The host presents the tour (first run, or re-presenting the next
    /// promise after an auto-return).
    case start
    /// The step's single action completed: auto-return to Home. The
    /// card comes down; the next promise waits for the host.
    case completeStep
    /// The host re-presents a step by index (the auto-return's other
    /// half). Never represents a dismissed or completed tour.
    case presentStep(index: Int)
    /// Back one promise; never before the first.
    case back
    /// Skip: always available while presenting, final for the session.
    case skip
}

/// The reducer: pure, total over intents. `TourViewState.apply(_:)` is
/// the convenience views use.
public enum TourReducer {

    public static func reduced(_ state: TourViewState, by intent: TourIntent) -> TourViewState {
        var next = state
        switch intent {

        case .stepsArrived(let steps):
            // The shortness constraint: truncate on arrival.
            next.steps = Array(steps.prefix(TourViewState.maxSteps))

        case .start:
            // A dismissed or completed tour stays finished for the
            // session; an off candidate never presents; an empty tour
            // cannot start.
            guard next.enabled,
                  !next.isFinished,
                  !next.steps.isEmpty
            else { break }
            next.stage = .presenting(index: 0)

        case .completeStep:
            guard case .presenting(let index) = next.stage else { break }
            if index + 1 < next.steps.count {
                // Auto-return: the card comes down, the app is usable.
                next.stage = .returnedHome(nextIndex: index + 1)
            } else {
                next.stage = .completed
            }

        case .presentStep(let index):
            // Host re-presentation: bounds-checked, never re-arms a
            // finished tour, never works while the flag is off.
            guard next.enabled,
                  !next.isFinished,
                  next.steps.indices.contains(index)
            else { break }
            next.stage = .presenting(index: index)

        case .back:
            guard case .presenting(let index) = next.stage, index > 0
            else { break }
            next.stage = .presenting(index: index - 1)

        case .skip:
            // Skip is final: dismissed for the session, never re-armed.
            guard next.enabled, !next.isFinished else { break }
            next.stage = .dismissed
        }
        return next
    }
}

extension TourViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: TourIntent) {
        self = TourReducer.reduced(self, by: intent)
    }
}
