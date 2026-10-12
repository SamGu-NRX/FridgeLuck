// FLProgress — Progress's typed intents and the reducer.
//
// The reducer owns the observable presentation transitions: profile and
// quests presentation, counter and week-list arrivals. The counters'
// arithmetic (the cook log, the week boundary, the streak's survival
// rule) is the host's — the reducer only records what the host hands
// over, in the host's order.

import Foundation

/// Everything the Progress screen can send.
public enum ProgressIntent: Equatable, Sendable {

    // Host-routed arrivals (the host owns the cook log)

    /// The recomputed counters, from the host's log.
    case countersArrived(ProgressViewState.Counters)
    /// This week's cooks, in the host's order.
    case weekCooksArrived([ProgressViewState.WeekCook])

    // Navigation (Profile lives inside Progress, per the shell decision)

    case openProfile
    case closeProfile

    /// The quests CANDIDATE's entry. Ignored unless the flag is on —
    /// a candidate cannot be reached by accident.
    case openQuests
    case closeQuests

    /// A week row: host routes to the cook's record.
    case openCook(id: String)
}

/// The reducer: pure, total over intents. `ProgressViewState.apply(_:)`
/// is the convenience views use.
public enum ProgressReducer {

    public static func reduced(_ state: ProgressViewState, by intent: ProgressIntent) -> ProgressViewState {
        var next = state
        switch intent {

        case .countersArrived(let counters):
            next.counters = counters

        case .weekCooksArrived(let cooks):
            next.weekCooks = cooks

        case .openProfile:
            next.profilePresented = true

        case .closeProfile:
            next.profilePresented = false

        case .openQuests:
            // The candidate flag gates the entry: off, the intent is
            // dropped and nothing presents.
            guard next.questsEnabled else { break }
            next.questsPresented = true

        case .closeQuests:
            next.questsPresented = false

        // Host-routed outcome: the host opens the cook's record.
        case .openCook:
            break
        }
        return next
    }
}

extension ProgressViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: ProgressIntent) {
        self = ProgressReducer.reduced(self, by: intent)
    }
}
