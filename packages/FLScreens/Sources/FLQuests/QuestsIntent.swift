// FLQuests — the quests candidate's typed intents and reducer.
//
// The reducer owns: join/leave (queue + reconcile while offline), the
// share preview's lifecycle, and host-routed arrivals. Leave is quiet —
// never an error, never a confirm (the mock: "never destructive red").
// The share preview is the only path to a payload, and the payload is
// the allowlist projected from the host's cook record.

import Foundation

/// Everything the quests screen can send.
public enum QuestsIntent: Equatable, Sendable {

    // Joining

    /// Join a quest. Offline (an `asOf` line present), the join queues.
    case join(id: String)
    /// Leave quietly: clears the joined state, drops any queued join.
    case leave(id: String)
    /// Back online: queued joins apply and the receipt confirms.
    case connectionRestored

    // Sharing (the SPEC §3.4 preview-approve contract)

    /// Ask to share the cook for a quest: opens the preview built from
    /// the host's cook record — the allowlist projection.
    case shareResult(id: String, record: QuestCookRecord)
    case cancelSharePreview
    /// The user approved; the host performs the share.
    case shareConfirmed

    // Host-routed arrivals

    case questsArrived([QuestsViewState.Quest])
    case countersArrived(cooksMade: Int, swapsUsed: Int, savedGrams: Int)
    case asOfArrived(String)
}

/// The reducer: pure, total over intents. `QuestsViewState.apply(_:)`
/// is the convenience views use.
public enum QuestsReducer {

    public static func reduced(_ state: QuestsViewState, by intent: QuestsIntent) -> QuestsViewState {
        var next = state
        switch intent {

        case .join(let id):
            // The candidate renders nothing while off; joins cannot
            // happen in a screen that never presented.
            guard next.enabled,
                  let index = next.quests.firstIndex(where: { $0.id == id })
            else { break }
            if next.quests[index].doneLine != nil { break }  // done quests do not re-join
            next.quests[index].isJoined = true
            if next.asOf != nil {
                // Offline: queue and say so — a visible receipt, never a
                // spinner pretending to have joined.
                if !next.pendingJoinIds.contains(id) {
                    next.pendingJoinIds.append(id)
                }
                next.joinReceipt = "You're in — this queued while offline."
            } else {
                next.joinReceipt = "You're in."
            }

        case .leave(let id):
            // Quiet: clear the joined state, drop a queued join, no
            // error state, no confirmation.
            next.quests = next.quests.map { quest in
                var updated = quest
                if quest.id == id { updated.isJoined = false }
                return updated
            }
            next.pendingJoinIds.removeAll { $0 == id }
            next.joinReceipt = nil

        case .connectionRestored:
            // Reconcile: queued joins apply, the receipt confirms.
            for id in next.pendingJoinIds {
                if let index = next.quests.firstIndex(where: { $0.id == id }) {
                    next.quests[index].isJoined = true
                }
            }
            if !next.pendingJoinIds.isEmpty {
                next.joinReceipt = "You're in — confirmed."
            }
            next.pendingJoinIds = []

        case .shareResult(let id, let record):
            // The only path to a payload: project the host's cook record
            // through the allowlist. Anything else in the cook log —
            // pantry state, health profile, taste, exact times — is
            // dropped by construction: the projection reads five fields.
            guard next.enabled,
                  let quest = next.quest(id: id)
            else { break }
            next.sharePreview = QuestSharePayload(
                questId: quest.id,
                questTitle: quest.title,
                revisionId: record.revisionId,
                servings: record.servings,
                swapsUsed: record.swapsUsed,
                rating: record.rating,
                noteLine: record.noteLine
            )

        case .cancelSharePreview:
            next.sharePreview = nil

        case .shareConfirmed:
            // The host performed the share; the preview closes.
            next.sharePreview = nil

        case .questsArrived(let quests):
            next.quests = quests

        case .countersArrived(let cooksMade, let swapsUsed, let savedGrams):
            next.weekCooksMade = cooksMade
            next.weekSwapsUsed = swapsUsed
            next.weekSavedGrams = savedGrams

        case .asOfArrived(let line):
            next.asOf = line
        }
        return next
    }
}

extension QuestsViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: QuestsIntent) {
        self = QuestsReducer.reduced(self, by: intent)
    }
}
