// FLProgress — Progress, the second Shell S tab.
//
// Shell S (Sam's stage-2 structure, SPEC §2) is Kitchen and Progress as
// the two main tabs, with Profile living inside Progress — the shell
// decision already recorded in FLScreenSupport's FLShellConfiguration
// (`shellS`). This module carries BOTH screens: Progress (this file) and
// the Profile screen it links to (`ProfileViewState.swift`), following
// the FLExplore precedent — two screens, one target, because one links
// from the other and they share the household/evidence vocabulary.
//
// Binding rules this state encodes (the Shell S Progress mock's notes +
// SPEC §2's candidate rules):
//
// - Every number here is computable from the cook log; nothing is a
//   score. The counters arrive from the host (which owns the log) as
//   values — the state layer derives display strings and nothing else,
//   exactly like FLFitSummary. Saved-from-waste is counted in grams of
//   food used before it spoiled.
// - First run: "Nothing here yet. Cook one thing." The counters render
//   as 0 (never dashes) and the week list is simply absent.
// - Week boundary, archiving and streak survival are the host's
//   arithmetic (it owns the log and the clock); the state renders the
//   week it is handed and never re-sorts it.
// - This screen is the user's OWN record: the week rows may carry the
//   cook's time of day because nothing here is ever surfaced to
//   community (SPEC §3.4's exclusion applies to what LEAVES the phone —
//   see FLQuests' share payload for the community side of that line).
// - Counters render from the local log at `.asOf` provenance; the sync
//   line states the cache age and nothing else.
// - Quests are a CANDIDATE (SPEC §2): the entry row renders only while
//   `questsEnabled` is on, and the flag ships OFF (lint-pinned in
//   Part6RawSourceLintTests).
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLProgressTests.

import Foundation
import FLScreenSupport

/// The whole Progress screen as a value.
public struct ProgressViewState: Equatable, Sendable {

    /// One cooked meal in this week's list.
    public struct WeekCook: Equatable, Sendable, Identifiable {

        public var id: String
        /// "Thu" — the day line.
        public var dayDisplay: String
        /// The dish, host-verbatim ("Butter bean curry").
        public var dishDisplay: String
        /// The rating, display form ("5").
        public var ratingDisplay: String
        /// The cook's own clock ("18:40"). Personal-surface only — this
        /// field must never reach a community payload (SPEC §3.4).
        public var timeDisplay: String

        public init(
            id: String, dayDisplay: String, dishDisplay: String,
            ratingDisplay: String, timeDisplay: String
        ) {
            self.id = id
            self.dayDisplay = dayDisplay
            self.dishDisplay = dishDisplay
            self.ratingDisplay = ratingDisplay
            self.timeDisplay = timeDisplay
        }
    }

    /// The three counters. The host computes them from the cook log; the
    /// state layer never infers one from the others.
    public struct Counters: Equatable, Sendable {

        public var cookedThisWeek: Int
        /// In whole weeks (the mock's "3 week streak").
        public var weekStreak: Int
        /// Grams of food used before it spoiled — the app's ecological
        /// promise in one number.
        public var savedFoodGrams: Int

        public init(cookedThisWeek: Int, weekStreak: Int, savedFoodGrams: Int) {
            self.cookedThisWeek = max(0, cookedThisWeek)
            self.weekStreak = max(0, weekStreak)
            self.savedFoodGrams = max(0, savedFoodGrams)
        }

        /// The log has nothing in it yet — first run.
        public var isEmptyLog: Bool {
            cookedThisWeek == 0 && weekStreak == 0 && savedFoodGrams == 0
        }
    }

    // MARK: State

    /// "week 41", host-verbatim; nil hides the caption.
    public var weekLabel: String?
    public var counters: Counters
    /// The week's cooks in the host's order (the mock's time order).
    /// Never re-sorted here — order is the host's statement.
    public var weekCooks: [WeekCook]
    /// Cached provenance while offline ("As of 18:40"). Counters render
    /// from the local log either way — they are local.
    public var asOf: String?
    /// The quests CANDIDATE's flag. Ships OFF; the entry row renders only
    /// while it is on.
    public var questsEnabled: Bool
    /// Presentation-only: the Profile screen is pushed (it lives inside
    /// Progress per the shell decision).
    public var profilePresented: Bool
    /// Presentation-only: the quests candidate screen is presented.
    public var questsPresented: Bool

    public init(
        weekLabel: String? = nil,
        counters: Counters = Counters(cookedThisWeek: 0, weekStreak: 0, savedFoodGrams: 0),
        weekCooks: [WeekCook] = [],
        asOf: String? = nil,
        questsEnabled: Bool = false
    ) {
        self.weekLabel = weekLabel
        self.counters = counters
        self.weekCooks = weekCooks
        self.asOf = asOf
        self.questsEnabled = questsEnabled
        self.profilePresented = false
        self.questsPresented = false
    }

    // MARK: Derived (always recomputed, never stored)

    /// First run: no cooks in the log. The counters render as 0 in the
    /// quiet colour and the empty-state copy stands in for the list.
    public var isFirstRun: Bool {
        weekCooks.isEmpty && counters.isEmptyLog
    }

    /// The saved-from-waste counter's display form ("1.2 kg"), shared
    /// with the quests candidate's counter so the two never drift.
    public var savedFoodDisplay: String {
        FLSavedFoodLine(grams: counters.savedFoodGrams).displayText
    }

    /// The quests entry row renders only behind the candidate flag —
    /// its absence is the off state, like Explore's Table entry.
    public var showsQuestsEntry: Bool {
        questsEnabled
    }
}
