// FLTour — the constrained onboarding tour candidate. CANDIDATE, not a
// cut.
//
// SPEC §2: the tour is a CANDIDATE, short and dismissible, and — the
// binding shape — the tour is NOT a tutorial; it is three promises:
// what the app will do, what stays on the phone, what you can undo.
// One screen per promise, auto-returns to Home after each step, skip
// is always available, back never goes before the first step, and a
// dismissed or completed tour never re-arms for the session.
//
// This whole target is droppable (delete target + tests) or promotable
// (flip the flag's default, remove the flag). The flag ships OFF —
// lint-pinned in Part6RawSourceLintTests — and every step arrives from
// the host verbatim: the state layer owns the machine, not the copy.
//
// Shortness is enforced: at most `maxSteps` steps (5; the mock's tour is
// 3). A longer list is truncated on arrival — the tour cannot quietly
// grow into an onboarding funnel.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLTourTests.

import Foundation

/// The whole tour as a value.
public struct TourViewState: Equatable, Sendable {

    /// One promise, host-verbatim.
    public struct Step: Equatable, Sendable, Identifiable {

        public var id: String
        /// The promise ("It learns your kitchen").
        public var title: String
        /// One or two sentences, host-verbatim.
        public var bodyText: String
        /// Optional photo caption; the photo itself is decorative and
        /// 3:2 through PhotoLayoutRule.
        public var photoCaption: String?
        /// The first step shows the fit meter starting at zero
        /// ("starts at zero, grows as it learns") — host-supplied
        /// have/total and its line; nil hides the block.
        public var fitHave: Int?
        public var fitTotal: Int?
        public var fitLine: String?
        /// The step's privacy lines ("Everything runs on your phone.",
        /// "You control what leaves, one preview at a time.").
        public var privacyLines: [String]
        /// The step's single action ("Scan your first shelf").
        public var primaryLabel: String

        public init(
            id: String, title: String, bodyText: String,
            photoCaption: String? = nil,
            fitHave: Int? = nil, fitTotal: Int? = nil, fitLine: String? = nil,
            privacyLines: [String] = [], primaryLabel: String
        ) {
            self.id = id
            self.title = title
            self.bodyText = bodyText
            self.photoCaption = photoCaption
            self.fitHave = fitHave
            self.fitTotal = fitTotal
            self.fitLine = fitLine
            self.privacyLines = privacyLines
            self.primaryLabel = primaryLabel
        }
    }

    /// Where the tour stands. `returnedHome` is the auto-return
    /// contract: after each step the card is DOWN and the app is
    /// usable; the host may present the next promise when it chooses.
    public enum Stage: Equatable, Sendable {
        case idle
        case presenting(index: Int)
        case returnedHome(nextIndex: Int?)
        case dismissed
        case completed
    }

    // MARK: State

    /// The CANDIDATE flag. Ships OFF (lint-pinned); the host turns it on
    /// for the beta cohort.
    public var enabled: Bool
    /// The promises, host-verbatim, host order. Truncated to `maxSteps`.
    public var steps: [Step]
    public var stage: Stage
    /// "no account needed" — the caption under the pager, host-verbatim.
    public var footerCaption: String?

    public init(enabled: Bool = false, steps: [Step] = [], footerCaption: String? = nil) {
        self.enabled = enabled
        self.steps = Array(steps.prefix(TourViewState.maxSteps))
        self.stage = .idle
        self.footerCaption = footerCaption
    }

    // MARK: Derived (always recomputed, never stored)

    /// How short the tour may be — the constraint that keeps it a tour.
    public static let maxSteps = 5

    public var isPresenting: Bool {
        guard case .presenting = stage else { return false }
        return true
    }

    public var isFinished: Bool {
        stage == .dismissed || stage == .completed
    }

    public var currentStep: Step? {
        guard case .presenting(let index) = stage,
              steps.indices.contains(index)
        else { return nil }
        return steps[index]
    }

    /// The presenting step's index, if presenting.
    public var currentIndex: Int? {
        guard case .presenting(let index) = stage else { return nil }
        return index
    }

    /// "1 of 3" — counts from one; nil while not presenting.
    public var pagerLine: String? {
        guard case .presenting(let index) = stage, !steps.isEmpty else { return nil }
        return "\(index + 1) of \(steps.count)"
    }
}
