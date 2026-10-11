// FLTasteProfile — the taste-profile edit screen's view state.
//
// The on-device learning ledger (Direction H's taste-profile mock): the
// page reads like a ledger, not a horoscope — sentences the app would say
// out loud, each with the count it is based on and a Right / Wrong
// control. Binding rules this state encodes:
//
// - No sliders, no percentages, no personality labels. Confidence lives
//   in language and in counts. Evidence is host-verbatim ("18 of 23",
//   "9 · 6 · 7", "3 cooks") with distinct opportunities and denominators
//   — never "N observations". This module never computes an evidence
//   string.
// - Three row states: default Right / Wrong; confirmed, where Right
//   holds in accent-soft and the row says what the app will now do
//   (host-verbatim confirmation line); rejected, where the row dims,
//   strikes, and reads "Won't use this." beside Undo. Nothing is deleted
//   on Wrong — it is excluded and kept, so the app does not re-learn it
//   next week. Undo restores exactly.
// - "Don't ask again" is a different control from "This is wrong": it
//   stops future prompts about the pattern without touching the record.
//   Offer rows ("You've never cooked fish here.") answer with
//   Suggest some / Not interested, plus the permanent Never suggest
//   door.
// - Explicit restrictions are the hard filters, applied before ranking
//   (product law). Setup-set ones are locked — never weakened here.
//   Additions dedupe case-insensitively and refuse empty names.
// - "LeChef remembers" notes forget with a visible receipt; undo
//   restores the note in place. "Forget everything" asks once with the
//   count of what will be deleted; explicit restrictions survive any
//   reset.
// - New users (under three cooks, filtered host-side) get one sentence
//   instead of the list.
// - Edits mark unsaved changes; persisting is the host's (.saveEdits
//   effect, .editsSaved / .editsFailed report back). Export and Edit
//   (setup) are host effects — learning runs on the phone; nothing
//   about taste leaves the device except by the export.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLTasteTests.

/// The whole taste ledger as a value.
public struct TasteViewState: Equatable, Sendable {

    // MARK: Rows

    /// Where a sentence stands in the ledger.
    public enum SentenceStatus: Equatable, Sendable {
        /// Default: asking Right / Wrong.
        case learning
        /// Right holds: the app acts on the pattern.
        case confirmed
        /// Wrong holds: excluded and kept; undo restores.
        case rejected
    }

    /// What kind of sentence it is.
    public enum SentenceKind: Equatable, Sendable {
        /// A pattern the app inferred ("You cook on weeknights…").
        case pattern
        /// An offer ("You've never cooked fish here.") with the three
        /// doors: Suggest some / Not interested / Never suggest.
        case offer
    }

    /// One learned sentence row.
    public struct Sentence: Equatable, Sendable, Identifiable {

        public var id: String
        /// The sentence the app would say out loud. Host-authored.
        public var text: String
        /// The evidence, host-verbatim ("18 of 23", "9 · 6 · 7"). Never
        /// computed here, never "N observations".
        public var evidenceDisplay: String
        public var kind: SentenceKind
        public var status: SentenceStatus
        /// What the app will now do, shown on confirmed rows
        /// ("Confirmed 3 Oct. Never suggested."). Host-verbatim.
        public var confirmationLine: String?
        /// "Don't ask again" / "Never suggest": stops future prompts
        /// about this pattern; the record stays.
        public var promptSuppressed: Bool
        /// Offer rows only: the polite no was given this time; only the
        /// Never suggest door remains.
        public var offerDeclined: Bool

        public init(
            id: String, text: String, evidenceDisplay: String,
            kind: SentenceKind = .pattern, status: SentenceStatus = .learning,
            confirmationLine: String? = nil, promptSuppressed: Bool = false,
            offerDeclined: Bool = false
        ) {
            self.id = id
            self.text = text
            self.evidenceDisplay = evidenceDisplay
            self.kind = kind
            self.status = status
            self.confirmationLine = confirmationLine
            self.promptSuppressed = promptSuppressed
            self.offerDeclined = offerDeclined
        }
    }

    /// One "LeChef remembers" note.
    public struct Memory: Equatable, Sendable, Identifiable {

        public var id: String
        /// The note ("Too salty. Low-sodium stock next time.").
        public var text: String
        /// The dish it belongs to, when the note is dish-specific.
        public var dishName: String?
        /// The date, host-verbatim ("3 Oct").
        public var dateDisplay: String

        public init(id: String, text: String, dishName: String? = nil, dateDisplay: String) {
            self.id = id
            self.text = text
            self.dishName = dishName
            self.dateDisplay = dateDisplay
        }
    }

    /// One explicit restriction — a hard filter applied before ranking.
    public struct Restriction: Equatable, Sendable, Identifiable {

        public var id: String
        public var name: String
        /// Setup-set restrictions are locked: never weakened on this
        /// screen.
        public var isLocked: Bool
        /// The lock's caption ("edited in setup").
        public var setupNote: String?

        public init(id: String, name: String, isLocked: Bool = false, setupNote: String? = nil) {
            self.id = id
            self.name = name
            self.isLocked = isLocked
            self.setupNote = setupNote
        }
    }

    /// A forgotten note held for undo, with its index so restore is in
    /// place.
    public struct ForgottenMemory: Equatable, Sendable {

        public var memory: Memory
        public var previousIndex: Int
    }

    // MARK: State

    /// New-user mode (under three cooks, filtered host-side): one
    /// sentence instead of the list.
    public var isNewUser: Bool
    /// The new user's line, host-verbatim ("Cook three things and I'll
    /// start writing this. Until then I'm using what you told me at
    /// setup.").
    public var newUserLine: String?
    /// The learned sentences, in ledger order.
    public var sentences: [Sentence]
    /// The remembered notes, newest first as the host hands them over.
    public var memories: [Memory]
    /// The most recent forget, held for undo until replaced.
    public var lastForgotten: ForgottenMemory?
    /// Explicit restrictions. Survive every reset.
    public var restrictions: [Restriction]
    /// The setup lines, host-verbatim ("No shellfish", "cooking for 2",
    /// "metric").
    public var setupSummary: [String]
    /// "23 cooks" — host-verbatim.
    public var cooksCountDisplay: String?
    /// The forget-everything confirmation is on the table (asked once,
    /// with the count).
    public var isConfirmingForgetAll: Bool
    /// An edit (feedback, forget, restriction change) is not yet
    /// persisted; the host saves through .saveEdits.
    public var hasUnsavedChanges: Bool
    /// The last save failed; the edits are kept.
    public var saveFailed: Bool

    public init(
        isNewUser: Bool = false, newUserLine: String? = nil,
        sentences: [Sentence] = [], memories: [Memory] = [],
        restrictions: [Restriction] = [], setupSummary: [String] = [],
        cooksCountDisplay: String? = nil
    ) {
        self.isNewUser = isNewUser
        self.newUserLine = newUserLine
        self.sentences = sentences
        self.memories = memories
        self.lastForgotten = nil
        self.restrictions = restrictions
        self.setupSummary = setupSummary
        self.cooksCountDisplay = cooksCountDisplay
        self.isConfirmingForgetAll = false
        self.hasUnsavedChanges = false
        self.saveFailed = false
    }

    // MARK: Restriction validation

    /// Normalise a restriction name for the dedup check: trimmed,
    /// lowercased, inner whitespace collapsed — the same rule Scan's
    /// dedup uses for item names.
    public static func normalizedRestriction(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .lowercased()
    }

    /// Whether a restriction with this name already exists
    /// (case-insensitive, whitespace-collapsed).
    public func hasRestriction(named name: String) -> Bool {
        let key = Self.normalizedRestriction(name)
        return restrictions.contains { Self.normalizedRestriction($0.name) == key }
    }

    // MARK: Counts

    /// What forget-everything would delete: the sentences and the
    /// remembered notes. Restrictions are not in the count — they
    /// survive.
    public var forgettableCount: Int { sentences.count + memories.count }

    /// The ask-once confirmation line for Forget everything. The count
    /// is what will be deleted; the sentence names what survives.
    public var forgetAllPromptDisplay: String {
        "Forget \(forgettableCount) things? Restrictions stay."
    }

    /// "LeChef remembers · 4" — the section's count.
    public var memoriesCountDisplay: String { String(memories.count) }
}
