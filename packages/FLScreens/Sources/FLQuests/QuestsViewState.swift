// FLQuests — the weekly quests candidate. CANDIDATE, not a cut.
//
// SPEC §2 is explicit: quests, badges and the tour are CANDIDATES that
// turn cuts into candidates, not committed cuts. This whole target is
// therefore droppable (delete the target and its tests) or promotable
// (flip the flag's default, remove the flag) with nothing else
// entangled. The flag ships OFF — a candidate cannot be reached by
// accident, and the default is lint-pinned in
// Part6RawSourceLintTests.
//
// Community-adjacent, privacy-safe (SPEC §3.4 + the overview): community
// cooks exclude pantry, health-profile, taste, and exact-time data. This
// state enforces that line STRUCTURALLY, in two places:
//
// 1. `QuestSharePayload` is the only value a share ever builds, and it
//    is an explicit allowlist — revision id, servings, swaps, rating,
//    optional one-line note, and the quest's own name. There is no field
//    a pantry line, a health profile, a taste embedding, or a timestamp
//    could arrive in; the projection reads only the five fields of the
//    host's `QuestCookRecord` and drops everything else by construction.
//    The Part 6 lint bans the excluded vocabularies from the payload's
//    declarations, the way Part 5 banned them from the Table's
//    LookResult.
// 2. Aggregate counters ("14 cooking", "3 cooks made it") are
//    host-supplied structured counts, never personal rows.
//
// "Joining queues and reconciles on reconnect, with a visible receipt"
// (mock): offline joins land in `pendingJoinIds` with a receipt line;
// `.connectionRestored` applies them. Rewards are display chips (an
// earned explore filter), never points, coins or a currency.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLQuestsTests.

import Foundation
import FLScreenSupport

/// What a share sends: the explicit allowlist, nothing else.
public struct QuestSharePayload: Equatable, Sendable {

    /// The quest's own id and name — needed so the share names itself.
    public var questId: String
    public var questTitle: String
    /// The cooked recipe revision, host-verbatim.
    public var revisionId: String
    public var servings: Int
    public var swapsUsed: Int
    /// Optional star rating, 1...5.
    public var rating: Int?
    /// Optional one-line note (the same disclosure as a Table post).
    public var noteLine: String?

    public init(
        questId: String, questTitle: String, revisionId: String,
        servings: Int, swapsUsed: Int, rating: Int? = nil, noteLine: String? = nil
    ) {
        self.questId = questId
        self.questTitle = questTitle
        self.revisionId = revisionId
        self.servings = servings
        self.swapsUsed = swapsUsed
        self.rating = rating
        self.noteLine = noteLine
    }

    /// The preview's lines — the share screen shows exactly these, so
    /// what leaves the phone is exactly what was approved.
    public var previewLines: [String] {
        var lines: [String] = []
        lines.append("Recipe: \(questTitle)")
        lines.append("Servings: \(servings)")
        lines.append("Swaps: \(swapsUsed)")
        if let rating {
            lines.append("Rating: \(rating)")
        }
        if let noteLine, !noteLine.isEmpty {
            lines.append("Note: \(noteLine)")
        }
        return lines
    }
}

/// The host's cook record for one quest cook — the five fields a share
/// may draw from. Everything else in the cook log stays behind the
/// projection.
public struct QuestCookRecord: Equatable, Sendable {

    public var revisionId: String
    public var servings: Int
    public var swapsUsed: Int
    public var rating: Int?
    public var noteLine: String?

    public init(
        revisionId: String, servings: Int, swapsUsed: Int,
        rating: Int? = nil, noteLine: String? = nil
    ) {
        self.revisionId = revisionId
        self.servings = servings
        self.swapsUsed = swapsUsed
        self.rating = rating
        self.noteLine = noteLine
    }
}

/// The whole quests screen as a value.
public struct QuestsViewState: Equatable, Sendable {

    /// One weekly quest.
    public struct Quest: Equatable, Sendable, Identifiable {

        public var id: String
        /// Host-verbatim ("Three ingredients, one dinner").
        public var title: String
        /// Host-verbatim one-liner.
        public var brief: String?
        /// "Works alone · any method · ends Sunday", host-verbatim.
        public var rulesLine: String
        /// "14 cooking" — a structured count the host supplies.
        public var cooksDisplay: String
        public var isJoined: Bool
        /// Set when the cook finished the quest: "You made 4 — this
        /// one's done", host-verbatim. Done quests hold their counter
        /// and swap their join controls for this line.
        public var doneLine: String?
        /// The earned filter chip ("under 30 min") — a display chip,
        /// never points or a currency.
        public var rewardChip: String?

        public init(
            id: String, title: String, brief: String? = nil,
            rulesLine: String, cooksDisplay: String,
            isJoined: Bool = false, doneLine: String? = nil,
            rewardChip: String? = nil
        ) {
            self.id = id
            self.title = title
            self.brief = brief
            self.rulesLine = rulesLine
            self.cooksDisplay = cooksDisplay
            self.isJoined = isJoined
            self.doneLine = doneLine
            self.rewardChip = rewardChip
        }
    }

    // MARK: State

    /// The CANDIDATE flag. Ships OFF (lint-pinned); the host turns it on
    /// for the beta cohort.
    public var enabled: Bool
    /// The week's quests in the host's order — never re-ranked here.
    public var quests: [Quest]
    /// The week's three counters, host-supplied values.
    public var weekCooksMade: Int
    public var weekSwapsUsed: Int
    /// Grams of food used before it spoiled, this week.
    public var weekSavedGrams: Int
    /// Cached provenance while offline ("As of 18:40").
    public var asOf: String?
    /// Joins queued while offline; applied on `.connectionRestored`.
    public var pendingJoinIds: [String]
    /// The visible receipt ("You're in — this queued while offline.").
    public var joinReceipt: String?
    /// The share preview being approved, if any.
    public var sharePreview: QuestSharePayload?

    public init(enabled: Bool = false, quests: [Quest] = []) {
        self.enabled = enabled
        self.quests = quests
        self.weekCooksMade = 0
        self.weekSwapsUsed = 0
        self.weekSavedGrams = 0
        self.asOf = nil
        self.pendingJoinIds = []
        self.joinReceipt = nil
        self.sharePreview = nil
    }

    // MARK: Derived (always recomputed, never stored)

    /// The candidate's content renders only while the flag is on.
    public var isActive: Bool {
        enabled
    }

    /// "3 this week" — the header caption, from the host's list.
    public var weekCaption: String {
        "\(quests.count) this week"
    }

    /// "620 g" — the week's saved counter, through the shared display
    /// grammar so Progress and Quests cannot drift.
    public var weekSavedDisplay: String {
        FLSavedFoodLine(grams: weekSavedGrams).displayText
    }

    /// No quests this week: the quiet empty copy stands in.
    public var showsEmpty: Bool {
        enabled && quests.isEmpty
    }

    /// The featured quest is the host's first; the rest are "Also this
    /// week". Order is the host's statement, not a ranking.
    public var featuredQuest: Quest? {
        quests.first
    }

    public var alsoQuests: [Quest] {
        Array(quests.dropFirst())
    }

    public func quest(id: String) -> Quest? {
        quests.first { $0.id == id }
    }
}
