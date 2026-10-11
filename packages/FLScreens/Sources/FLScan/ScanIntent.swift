// FLScan — typed intents and the reducer.
//
// Two kinds, as everywhere in FLScreens:
//
// - Presentation-logic intents: the reducer applies them (the stage
//   machine, dedup answers, uncertain-item answers, edits, the commit's
//   idempotence) so the rules are Linux-testable.
// - Navigation/effect intents: routed to the host through the view's
//   send closure; the reducer returns state unchanged, because the
//   outcome (a camera frame, recognition results, the pantry write)
//   arrives as new state from the host, not from this layer.
//
// The commit is idempotent at the state level: a second `.confirmCommit`
// while saving is ignored, so a double tap cannot double-write. The
// host's own confirmation replay ("Kitchen unchanged") rides on the same
// guarantee.

import Foundation

/// Everything the Scan flow can send.
public enum ScanIntent: Equatable, Sendable {

    // Flow (reducer-owned stage machine)

    /// Enter the capture screen from the idle landing.
    case startCapture
    /// The host reports the camera permission was refused.
    case cameraDenied
    /// The host reports the camera failed to open or run.
    case cameraFailed
    /// The shutter produced a photo; the host classified the run and
    /// hands over its kind and the photo's working caption. Recognition
    /// starts; results stream in afterwards.
    case captureTaken(kind: ScanViewState.RunKind, photoCaption: String?)
    /// The quality gate rejected the capture before upload (shown over
    /// the photo, never as an alert).
    case captureRejected(ScanViewState.CaptureIssue)
    /// Retake: back to the camera, clearing any quality issue or
    /// recognition problem. From a failed review it starts a new capture;
    /// the failed photo's problem is cleared either way.
    case retake
    /// Leave the flow (the host dismisses the destination). The scan is
    /// abandoned — nothing was committed, nothing is remembered.
    case closeCapture

    // Recognition (reducer-owned ingestion; the network is the host's)

    /// A recognition batch landed. Results coalesce by normalised name
    /// (an echo never duplicates a row) and classify against the pantry
    /// snapshot. Applies while recognising only — the mock's rows appear
    /// as recognised.
    case recognitionProgress(
        recognised: [ScanViewState.RecognizedItem], uncertain: [ScanViewState.UncertainItem]
    )
    /// The stream ended with results: review begins.
    case recognitionFinished
    /// The stream failed: the photo stays, retry keeps it.
    case recognitionFailed
    /// The stream ended having recognised nothing usable.
    case recognisedNothing
    /// Retry recognition on the same photo — no re-capture required.
    case retryRecognition

    // Review edits (reducer-owned)

    /// Answer a "needs you" row with one of its likely names. The row
    /// moves to the sure list — classified against the pantry, so a
    /// chosen name that is already in the kitchen becomes a duplicate
    /// question, not a double add.
    case answerUncertain(itemID: String, name: String)
    /// "Neither" — the row was a misread; it leaves the scan.
    case rejectUncertain(itemID: String)
    /// The observe-versus-purchase answer on a duplicate.
    case answerDuplicate(itemID: String, stillThere: Bool)
    /// Remove a sure row from this scan (the mock's swipe-to-remove).
    case removeItem(itemID: String)
    /// "Missed something? Add by name" inside the review. Empty or
    /// whitespace names are refused. The row classifies against the
    /// pantry like any other; an unknown quantity stays "?".
    case addItemManually(name: String, quantityDisplay: String)
    /// The plate offer's answer. Yes is a host effect (the meal-log flow
    /// opens) — the scan never auto-switches; No just closes the offer.
    case answerPlateSwitch(logMeal: Bool)

    // Commit (reducer-owned stage machine; the pantry write is the host's)

    /// "Add N to kitchen". Idempotent: ignored unless reviewing.
    case confirmCommit
    /// The host confirmed the pantry write landed. Terminal for the flow.
    case commitSucceeded
    /// The write failed: back to the review with everything intact and a
    /// quiet line above the dock.
    case commitFailed

    // Navigation / effects (host-routed; reducer is identity)

    /// The "Add by hand" escape from a refused or failed camera.
    case openManualEntry
    /// The review's "Missed something? Add by name" row — opens the
    /// host's manual-entry flow (with the scan preserved).
    case addByName
    /// The plate offer's Yes — opens the meal-log flow host-side.
    case logMeal
    /// The shutter was pressed — the host runs the capture pipeline and
    /// reports back `.captureTaken` or `.captureRejected`.
    case shutter
}

/// The reducer: pure, total over intents. `ScanViewState.apply(_:)` is
/// the convenience views use.
public enum ScanReducer {

    public static func reduced(_ state: ScanViewState, by intent: ScanIntent) -> ScanViewState {
        var next = state
        switch intent {

        // MARK: Flow

        case .startCapture:
            guard next.stage == .idle else { break }
            next = ScanViewState(pantryItems: next.pantryItems)
            next.stage = .capturing

        case .cameraDenied:
            guard next.stage == .capturing else { break }
            next.cameraFailure = .denied

        case .cameraFailed:
            guard next.stage == .capturing else { break }
            next.cameraFailure = .failed

        case .captureTaken(let kind, let caption):
            guard next.stage == .capturing, next.cameraFailure == nil else { break }
            next.stage = .recognizing
            next.runKind = kind
            next.photoCaption = caption
            next.captureIssue = nil

        case .captureRejected(let issue):
            guard next.stage == .capturing, next.cameraFailure == nil else { break }
            next.captureIssue = issue

        case .retake:
            // From a quality-gated capture or a failed review: a new
            // capture on the same flow. Everything seen so far is
            // cleared — a retake is a new run, not an append.
            switch next.stage {
            case .capturing:
                next.captureIssue = nil
            case .reviewing, .recognizing:
                next = ScanViewState(pantryItems: next.pantryItems)
                next.stage = .capturing
            default:
                break
            }

        case .closeCapture:
            next = ScanViewState(pantryItems: next.pantryItems)

        // MARK: Recognition

        case .recognitionProgress(let recognised, let uncertain):
            guard next.stage == .recognizing else { break }
            // Ingest in two passes: coalesce the batch against the sure
            // list (echoes dropped), then classify each survivor against
            // the pantry. Uncertain rows join as questions.
            let coalesced = ScanViewState.coalescing(recognised.map(next.classified), into: next.sureItems)
            next.sureItems = coalesced
            let knownIDs = Set(next.uncertainItems.map({ $0.id }))
            for item in uncertain where !knownIDs.contains(item.id) {
                guard !item.options.isEmpty else { continue }
                next.uncertainItems.append(item)
            }

        case .recognitionFinished:
            guard next.stage == .recognizing else { break }
            next.stage = .reviewing

        case .recognitionFailed:
            guard next.stage == .recognizing else { break }
            next.recognitionProblem = .requestFailed
            next.stage = .reviewing

        case .recognisedNothing:
            guard next.stage == .recognizing else { break }
            next.recognitionProblem = .nothingRecognised
            next.stage = .reviewing

        case .retryRecognition:
            // Only from a failed review. The photo (caption, run kind)
            // stays; results restart empty — coalescing would make a
            // full re-land idempotent anyway, but a retry must not show
            // stale partial rows above the problem line.
            guard next.stage == .reviewing, next.recognitionProblem != nil else { break }
            next.recognitionProblem = nil
            next.sureItems = []
            next.uncertainItems = []
            next.stage = .recognizing

        // MARK: Review edits

        case .answerUncertain(let itemID, let name):
            guard let index = next.uncertainItems.firstIndex(where: { $0.id == itemID }) else { break }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            let uncertain = next.uncertainItems.remove(at: index)
            var row = ScanViewState.RecognizedItem(
                id: uncertain.id, name: trimmed,
                quantityDisplay: ScanViewState.PantryItem(name: trimmed, quantityDisplay: "?").quantityDisplay
            )
            // An unknown amount stays "?" — the scan never invents grams.
            row.quantityDisplay = "?"
            row = next.classified(row)
            next.sureItems.append(row)

        case .rejectUncertain(let itemID):
            guard let index = next.uncertainItems.firstIndex(where: { $0.id == itemID }) else { break }
            next.uncertainItems.remove(at: index)

        case .answerDuplicate(let itemID, let stillThere):
            guard let index = next.sureItems.firstIndex(where: { $0.id == itemID }) else { break }
            guard next.sureItems[index].isExisting else { break }
            next.sureItems[index].dedup = stillThere ? .stillThere : .boughtMore

        case .removeItem(let itemID):
            guard let index = next.sureItems.firstIndex(where: { $0.id == itemID }) else { break }
            next.sureItems.remove(at: index)

        case .addItemManually(let name, let quantityDisplay):
            guard next.stage == .reviewing || next.stage == .saving else { break }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            next.manualAddCount += 1
            let quantity = quantityDisplay.trimmingCharacters(in: .whitespaces)
            var row = ScanViewState.RecognizedItem(
                id: "manual-" + String(next.manualAddCount), name: trimmed,
                quantityDisplay: quantity.isEmpty ? "?" : quantity,
                source: .manual
            )
            row = next.classified(row)
            next.sureItems.append(row)

        case .answerPlateSwitch(let logMeal):
            guard next.runKind == .plate, !next.plateOfferAnswered else { break }
            next.plateOfferAnswered = true
            // Yes is still host-routed (`.logMeal`); the offer closing is
            // the only state change — the scan never auto-switches.

        // MARK: Commit

        case .confirmCommit:
            // Idempotent: only a review commits, and only once. A second
            // tap while saving changes nothing.
            guard next.stage == .reviewing else { break }
            next.stage = .saving
            next.commitFailed = false

        case .commitSucceeded:
            guard next.stage == .saving else { break }
            next.stage = .committed

        case .commitFailed:
            guard next.stage == .saving else { break }
            next.stage = .reviewing
            next.commitFailed = true

        // MARK: Effects

        case .openManualEntry, .addByName, .logMeal, .shutter:
            break
        }
        return next
    }
}

extension ScanViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: ScanIntent) {
        self = ScanReducer.reduced(self, by: intent)
    }
}
