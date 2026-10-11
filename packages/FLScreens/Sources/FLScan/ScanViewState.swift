// FLScan — the Scan flow's view state.
//
// The grocery capture-and-review flow (Direction H's scan-review mock):
// the camera captures, recognition streams its results in, and the screen
// asks only the questions the camera could not answer — the "needs you"
// rows come first and alone, then the sure rows as a list to skim.
// Binding rules this state encodes:
//
// - A shelf scan OBSERVES; it never adds stock on its own. Only a receipt
//   run, "Bought more", or manual entry changes a quantity. An item the
//   pantry already has becomes an observe-versus-purchase question
//   ("Still 2?" / "Bought more") — undecided duplicates default to
//   observe, because a scan never adds.
// - Unanswered "needs you" rows never block the commit: they go to
//   Kitchen's needs-a-look queue as unconfirmed entries.
// - Quantities arrive recognised, verbatim. The scan never invents grams
//   from the look of a bag — an unknown amount stays "?".
// - Recognition results are sure or a question — never a number the
//   user is asked to weigh. The header count is mono because it is a
//   number the user checks against the shelf.
// - Errors are escapes, never dead ends: camera refused or failed opens
//   onto manual entry; a failed recognition keeps the photo and retries
//   without a re-capture.
// - A camera run that saw a cooked dish never auto-switches to meal
//   logging — the offer is a question with Yes / No.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLScanTests.

/// The whole Scan flow as a value.
public struct ScanViewState: Equatable, Sendable {

    // MARK: Stage

    /// Where the flow stands. `recognizing` covers the mock's analysing
    /// state (title "Looking", rows appearing as recognised);
    /// `reviewing` is the review screen; `saving` is the commit in
    /// flight; `committed` is the terminal state the host routes away
    /// (no celebration — the pick updates when the kitchen does).
    public enum Stage: Equatable, Sendable {
        case idle
        case capturing
        case recognizing
        case reviewing
        case saving
        case committed
    }

    /// What the camera run saw — the header names it ("Shelf"). A receipt
    /// run adds stock and carries each row's verbatim receipt line; a
    /// plate run raises the meal-log offer. Classification is the host's;
    /// the state only carries the answer.
    public enum RunKind: Equatable, Sendable {
        case shelf
        case receipt
        case plate
    }

    /// A capture-quality rejection detected before upload, shown over the
    /// photo — never as an alert.
    public enum CaptureIssue: Equatable, Sendable {
        case tooDark
        case tooBlurry
    }

    /// The camera itself is unavailable. Never a dead end: the flow's
    /// escape is manual entry.
    public enum CameraFailure: Equatable, Sendable {
        /// Permission refused — "Camera off. Add by hand any time."
        case denied
        /// Hardware or session failure.
        case failed
    }

    /// Recognition could not finish usefully. The photo stays; retry
    /// keeps it too — no re-capture is required.
    public enum RecognitionProblem: Equatable, Sendable {
        /// "Nothing I recognise. Try one shelf, straight on, with the
        /// door light on."
        case nothingRecognised
        /// "Couldn't read this photo. Try again or add by name."
        case requestFailed
    }

    // MARK: Items

    /// One row of the pantry as the dedup saw it at scan time. The host
    /// supplies the snapshot; the state matches by normalised name and
    /// carries the pantry's own quantity into the duplicate question
    /// ("Still 2?" — the 2 is the pantry's, never guessed).
    public struct PantryItem: Equatable, Sendable {

        public var name: String
        public var quantityDisplay: String

        public init(name: String, quantityDisplay: String) {
            self.name = name
            self.quantityDisplay = quantityDisplay
        }
    }

    /// Where a sure row came from.
    public enum ItemSource: Equatable, Sendable {
        /// The camera recognised it.
        case recognition
        /// The user added it by name inside the review.
        case manual
    }

    /// The observe-versus-purchase answer for a duplicate. `pending` is
    /// the undecided default and resolves to observe: a scan never adds.
    public enum DedupAnswer: Equatable, Sendable {
        case pending
        case stillThere
        case boughtMore
    }

    /// One sure row — recognised or manually added.
    public struct RecognizedItem: Equatable, Sendable, Identifiable {

        public var id: String
        /// The normalised display name ("Greek yogurt").
        public var name: String
        /// The recognised quantity, verbatim ("4", "500 g", "open", "?").
        /// Never re-derived here.
        public var quantityDisplay: String
        /// The pantry already carries this name (dedup matched).
        public var isExisting: Bool
        /// The pantry's own quantity, when `isExisting` — the "Still 2?"
        /// number.
        public var existingQuantityDisplay: String?
        /// The observe-versus-purchase answer. Non-duplicates are always
        /// `pending` and add stock on commit.
        public var dedup: DedupAnswer
        /// For receipt runs: the receipt's own line, shown as a caption
        /// under the normalised name ("ORG SPNCH 200G").
        public var receiptLine: String?
        public var source: ItemSource

        public init(
            id: String, name: String, quantityDisplay: String,
            isExisting: Bool = false, existingQuantityDisplay: String? = nil,
            dedup: DedupAnswer = .pending, receiptLine: String? = nil,
            source: ItemSource = .recognition
        ) {
            self.id = id
            self.name = name
            self.quantityDisplay = quantityDisplay
            self.isExisting = isExisting
            self.existingQuantityDisplay = existingQuantityDisplay
            self.dedup = dedup
            self.receiptLine = receiptLine
            self.source = source
        }
    }

    /// One "needs you" row: a question the camera could not answer, with
    /// the likely names as chips and "Neither" as the escape.
    public struct UncertainItem: Equatable, Sendable, Identifiable {

        public var id: String
        /// What the camera saw, one line ("Leafy, pale stems, top shelf.").
        public var observedLine: String
        /// The thumbnail crop's working caption, when there is one.
        public var thumbCaption: String?
        /// The likely names, in the host's order. Never empty — an
        /// unresolvable result is a recognition problem, not a question.
        public var options: [String]

        public init(id: String, observedLine: String, thumbCaption: String? = nil, options: [String]) {
            self.id = id
            self.observedLine = observedLine
            self.thumbCaption = thumbCaption
            self.options = options
        }
    }

    // MARK: State

    public var stage: Stage
    public var runKind: RunKind?
    /// The captured photo's working caption ("Shelf", "Receipt"), shown
    /// through the photo placeholder area while recognising and on failure.
    public var photoCaption: String?
    /// Set when the quality gate rejected a capture before upload.
    public var captureIssue: CaptureIssue?
    /// Set when the camera itself is unavailable. The flow opens onto
    /// manual entry — never a dead end.
    public var cameraFailure: CameraFailure?
    /// Set when recognition finished without a usable answer.
    public var recognitionProblem: RecognitionProblem?
    /// The sure rows, in arrival order.
    public var sureItems: [RecognizedItem]
    /// The "needs you" rows, in arrival order.
    public var uncertainItems: [UncertainItem]
    /// The plate run's offer was answered; the offer never re-asks and
    /// never auto-switched in the first place.
    public var plateOfferAnswered: Bool
    /// Set when the commit failed; the review keeps everything and the
    /// quiet line above the dock names it.
    public var commitFailed: Bool
    /// Counter for manual rows' stable ids.
    var manualAddCount: Int

    /// The pantry snapshot the host handed in for dedup.
    public var pantryItems: [PantryItem]

    public init(
        stage: Stage = .idle, runKind: RunKind? = nil, photoCaption: String? = nil,
        captureIssue: CaptureIssue? = nil, cameraFailure: CameraFailure? = nil,
        recognitionProblem: RecognitionProblem? = nil,
        sureItems: [RecognizedItem] = [], uncertainItems: [UncertainItem] = [],
        plateOfferAnswered: Bool = false, commitFailed: Bool = false,
        pantryItems: [PantryItem] = []
    ) {
        self.stage = stage
        self.runKind = runKind
        self.photoCaption = photoCaption
        self.captureIssue = captureIssue
        self.cameraFailure = cameraFailure
        self.recognitionProblem = recognitionProblem
        self.sureItems = sureItems
        self.uncertainItems = uncertainItems
        self.plateOfferAnswered = plateOfferAnswered
        self.commitFailed = commitFailed
        self.pantryItems = pantryItems
        self.manualAddCount = 0
    }

    // MARK: Dedup — normalisation and classification

    /// The name key dedup matches on: trimmed, lowercased, inner
    /// whitespace collapsed. Same rules for the pantry snapshot and for
    /// recognition results, so "  greek  yogurt " matches "Greek yogurt".
    public static func normalizedName(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .lowercased()
    }

    /// The pantry row matching `name`, if dedup has one.
    public func pantryMatch(for name: String) -> PantryItem? {
        let key = Self.normalizedName(name)
        return pantryItems.first { Self.normalizedName($0.name) == key }
    }

    /// Coalesce a recognition batch: within one run, a later result whose
    /// normalised name matches an earlier row is an echo — the earlier
    /// row stands (first quantity wins; neither is invented). Echoes are
    /// dropped, which is what makes a retry of a failed request idempotent.
    public static func coalescing(_ incoming: [RecognizedItem], into existing: [RecognizedItem]) -> [RecognizedItem] {
        var result = existing
        var seen = Set(result.map { normalizedName($0.name) })
        for item in incoming {
            let key = normalizedName(item.name)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    /// Classify a row against the pantry snapshot: a matched name marks
    /// the row existing and carries the pantry's quantity into the
    /// "Still N?" question. Answers stay untouched.
    public func classified(_ item: RecognizedItem) -> RecognizedItem {
        guard let match = pantryMatch(for: item.name) else {
            var fresh = item
            fresh.isExisting = false
            fresh.existingQuantityDisplay = nil
            return fresh
        }
        var classified = item
        classified.isExisting = true
        classified.existingQuantityDisplay = match.quantityDisplay
        return classified
    }

    // MARK: Counts — the header's mono numbers

    /// Everything the scan currently holds: sure rows plus unanswered
    /// questions. This is the header's "N seen".
    public var seenCount: Int { sureItems.count + uncertainItems.count }

    /// The sure rows — the header's "M sure".
    public var sureCount: Int { sureItems.count }

    /// The dock's count: every row the commit records. Sure rows record
    /// at minimum an observation; unanswered "needs you" rows enter the
    /// needs-a-look queue. Removed and "Neither" rows record nothing.
    public var commitCount: Int { seenCount }

    /// Rows that change a stock number: new items plus "Bought more"
    /// duplicates. The honest sub-count the dock's caption does not
    /// advertise but the host's commit applies.
    public var stockAddCount: Int {
        sureItems.filter { !$0.isExisting || $0.dedup == .boughtMore }.count
    }

    /// Unanswered "needs you" rows — they enter Kitchen's needs-a-look
    /// queue as unconfirmed entries instead of blocking the commit.
    public var needsALookCount: Int { uncertainItems.count }

    // MARK: Display grammar

    /// "14 seen · 11 sure" — the header's mono count, reviewing only.
    public var headerCountDisplay: String? {
        guard stage == .reviewing || stage == .saving else { return nil }
        return "\(seenCount) seen · \(sureCount) sure"
    }

    /// The header title: "Looking" while analysing; "Found N things" when
    /// every row is sure; "Scan" otherwise.
    public var titleDisplay: String {
        switch stage {
        case .recognizing:
            return "Looking"
        case .reviewing, .saving:
            if uncertainItems.isEmpty && !sureItems.isEmpty && recognitionProblem == nil {
                return "Found \(sureItems.count) things"
            }
            return "Scan"
        case .idle, .capturing, .committed:
            return "Scan"
        }
    }

    /// "All look right." — the all-sure subtitle, and only then.
    public var subtitleDisplay: String? {
        guard stage == .reviewing || stage == .saving else { return nil }
        guard uncertainItems.isEmpty, !sureItems.isEmpty, recognitionProblem == nil else { return nil }
        return "All look right."
    }

    /// The mock's copy for the recognition problems, verbatim.
    public var problemDisplay: String? {
        switch recognitionProblem {
        case .nothingRecognised:
            return "Nothing I recognise. Try one shelf, straight on, with the door light on."
        case .requestFailed:
            return "Couldn't read this photo. Try again or add by name."
        case nil:
            return nil
        }
    }

    /// The camera refusal's copy — an escape, never a dead end.
    public var cameraFailureDisplay: String? {
        switch cameraFailure {
        case .denied: return "Camera off. Add by hand any time."
        case .failed: return "The camera didn't open. Add by hand any time."
        case nil: return nil
        }
    }

    /// The quality gate's copy, shown over the photo.
    public var captureIssueDisplay: String? {
        switch captureIssue {
        case .tooDark: return "Too dark to read"
        case .tooBlurry: return "Too blurry"
        case nil: return nil
        }
    }

    /// The plate run's offer — shown until answered, never auto-applied.
    public var showsPlateOffer: Bool {
        runKind == .plate && !plateOfferAnswered
    }

    /// The dock's primary title: "Add 14 to kitchen".
    public var commitButtonTitle: String {
        "Add \(commitCount) to kitchen"
    }

    /// The dock's caption: why the commit matters.
    public var commitCaption: String {
        "Tonight's pick updates when you do."
    }
}
