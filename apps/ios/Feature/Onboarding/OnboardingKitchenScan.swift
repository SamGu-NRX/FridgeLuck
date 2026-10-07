import UIKit

/// What recognition returned for one capture step's photos.
enum OnboardingKitchenScanResult {
  case notCaptured
  case scanned([Detection])
  case failed

  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

/// Recognition results for the photos the user took. `OnboardingView` keeps it, so leaving the
/// review and coming back rescans only if the photos changed.
struct OnboardingKitchenScanSession {
  let fridgePhotoIDs: [UUID]
  let pantryPhotoIDs: [UUID]
  let fridge: OnboardingKitchenScanResult
  let pantry: OnboardingKitchenScanResult

  func covers(
    fridgePhotos: [FLCapturedPhoto],
    pantryPhotos: [FLCapturedPhoto]
  ) -> Bool {
    fridgePhotoIDs == fridgePhotos.map(\.id) && pantryPhotoIDs == pantryPhotos.map(\.id)
  }

  var reviewState: OnboardingKitchenReviewState {
    OnboardingKitchenReview.state(fridge: fridge, pantry: pantry)
  }
}

/// What one location's section shows once its photos were scanned.
enum OnboardingKitchenSectionContent {
  case notCaptured
  case failed
  /// The scan ran and recognized nothing in this location's photos.
  case nothingFound
  /// May be empty when every item here was also found, with a higher score, in the other
  /// location; the section is then hidden rather than claiming nothing was found.
  case items([Detection])

  var detections: [Detection] {
    if case .items(let detections) = self { return detections }
    return []
  }
}

enum OnboardingKitchenReviewState {
  /// The user skipped both photo steps.
  case nothingCaptured
  /// Every scan that ran succeeded and none recognized an ingredient.
  case nothingFound
  /// No scan produced items and at least one failed, so "nothing found" would be untrue.
  case failed
  case review(fridge: OnboardingKitchenSectionContent, pantry: OnboardingKitchenSectionContent)

  /// The detections the review shows, one per ingredient. Empty outside `.review`.
  var detections: [Detection] {
    guard case .review(let fridge, let pantry) = self else { return [] }
    return fridge.detections + pantry.detections
  }
}

enum OnboardingKitchenReview {
  static func state(
    fridge: OnboardingKitchenScanResult,
    pantry: OnboardingKitchenScanResult
  ) -> OnboardingKitchenReviewState {
    if case .notCaptured = fridge, case .notCaptured = pantry {
      return .nothingCaptured
    }

    let split = sections(fridge: found(in: fridge), pantry: found(in: pantry))
    if split.fridge.isEmpty && split.pantry.isEmpty {
      return fridge.isFailed || pantry.isFailed ? .failed : .nothingFound
    }

    return .review(
      fridge: content(for: fridge, shown: split.fridge),
      pantry: content(for: pantry, shown: split.pantry)
    )
  }

  /// Puts each ingredient in one section only, the one where it scored higher (the fridge on a
  /// tie). Selection and intake are keyed by ingredient, so a second card would toggle with the
  /// first, and intake would store the estimate twice while the review showed it once.
  /// Each section lists sure items first, then uncertain, then possible, by score within each.
  static func sections(
    fridge: [Detection],
    pantry: [Detection]
  ) -> (fridge: [Detection], pantry: [Detection]) {
    var best: [Int64: (inFridge: Bool, detection: Detection)] = [:]
    let tagged =
      fridge.map { (inFridge: true, detection: $0) }
      + pantry.map { (inFridge: false, detection: $0) }
    for candidate in tagged {
      if let current = best[candidate.detection.ingredientId],
        current.detection.confidence >= candidate.detection.confidence
      {
        continue
      }
      best[candidate.detection.ingredientId] = candidate
    }

    let kept = best.values
    return (
      fridge: ordered(kept.filter { $0.inFridge }.map { $0.detection }),
      pantry: ordered(kept.filter { !$0.inFridge }.map { $0.detection })
    )
  }

  /// Preselects only items `ConfidenceRouter` routes to `.auto`. Uncertain and possible items
  /// start unchecked and need a tap. Ingredients the user already reviewed keep their state, so
  /// a rescan can't re-check something they unchecked or clear something they checked.
  static func selection(
    for detections: [Detection],
    keeping previousSelection: Set<Int64> = [],
    reviewed previousDetections: [Detection] = []
  ) -> Set<Int64> {
    let reviewed = Set(previousDetections.map(\.ingredientId))
    var selection = previousSelection.intersection(detections.map(\.ingredientId))
    for detection in detections
    where !reviewed.contains(detection.ingredientId)
      && ConfidenceRouter.bucket(for: detection) == .auto
    {
      selection.insert(detection.ingredientId)
    }
    return selection
  }

  /// What VoiceOver announces when a scan finishes.
  static func announcement(
    for state: OnboardingKitchenReviewState,
    selectedCount: Int
  ) -> String {
    switch state {
    case .nothingCaptured:
      return "No photos to scan."
    case .nothingFound:
      return "No ingredients found in these photos."
    case .failed:
      return "Couldn\u{2019}t read your photos. Try again, or continue."
    case .review(let fridge, let pantry):
      let found = fridge.detections.count + pantry.detections.count
      let noun = found == 1 ? "ingredient" : "ingredients"
      var message = "Found \(found) \(noun), \(selectedCount) selected."
      if case .failed = fridge { message += " Couldn\u{2019}t read your fridge photos." }
      if case .failed = pantry { message += " Couldn\u{2019}t read your pantry photos." }
      return message
    }
  }

  /// Built the way `ScanView.processImage()` builds them: the photo's own source, and its
  /// position among this location's photos as the capture index.
  static func scanInputs(for photos: [FLCapturedPhoto]) -> [ScanInput] {
    photos.enumerated().compactMap { index, photo in
      guard let image = photo.image.cgImage else { return nil }
      return ScanInput(image: image, source: photo.source, captureIndex: index)
    }
  }

  private static func found(in result: OnboardingKitchenScanResult) -> [Detection] {
    if case .scanned(let detections) = result { return detections }
    return []
  }

  private static func content(
    for result: OnboardingKitchenScanResult,
    shown: [Detection]
  ) -> OnboardingKitchenSectionContent {
    switch result {
    case .notCaptured:
      return .notCaptured
    case .failed:
      return .failed
    case .scanned(let recognized):
      return recognized.isEmpty ? .nothingFound : .items(shown)
    }
  }

  private static func ordered(_ detections: [Detection]) -> [Detection] {
    detections.sorted { lhs, rhs in
      let lhsRank = rank(ConfidenceRouter.bucket(for: lhs))
      let rhsRank = rank(ConfidenceRouter.bucket(for: rhs))
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
      return lhs.label < rhs.label
    }
  }

  private static func rank(_ bucket: ConfidenceBucket) -> Int {
    switch bucket {
    case .auto: return 0
    case .confirm: return 1
    case .possible: return 2
    }
  }
}

/// A finished scan and the selection the review should show for it.
struct OnboardingKitchenScanUpdate {
  let session: OnboardingKitchenScanSession
  let selection: Set<Int64>
}

/// Runs recognition on the onboarding photos, fridge and pantry as separate scans so each item
/// lands in the section of the photo it came from.
@MainActor
enum OnboardingKitchenScanner {
  /// What the review step runs: `run`, then the selection for the new results. The user's
  /// choices carry over even when the photos changed: an ingredient already shown keeps its
  /// checked state, and only sure items seen for the first time are checked.
  static func update(
    fridgePhotos: [FLCapturedPhoto],
    pantryPhotos: [FLCapturedPhoto],
    previous: OnboardingKitchenScanSession?,
    selection: Set<Int64>,
    retryFailed: Bool,
    scan: ([ScanInput]) async throws -> [Detection]
  ) async -> OnboardingKitchenScanUpdate? {
    guard
      let session = await run(
        fridgePhotos: fridgePhotos,
        pantryPhotos: pantryPhotos,
        previous: previous,
        retryFailed: retryFailed,
        scan: scan
      )
    else { return nil }

    return OnboardingKitchenScanUpdate(
      session: session,
      selection: OnboardingKitchenReview.selection(
        for: session.reviewState.detections,
        keeping: selection,
        reviewed: previous?.reviewState.detections ?? []
      )
    )
  }

  /// Scans every captured location when the photos are new. When they match `previous`, scans
  /// only failed locations and only if `retryFailed`; returns nil when there is nothing to do.
  static func run(
    fridgePhotos: [FLCapturedPhoto],
    pantryPhotos: [FLCapturedPhoto],
    previous: OnboardingKitchenScanSession?,
    retryFailed: Bool,
    scan: ([ScanInput]) async throws -> [Detection]
  ) async -> OnboardingKitchenScanSession? {
    let reused: OnboardingKitchenScanSession?
    if let previous, previous.covers(fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos) {
      guard retryFailed, previous.fridge.isFailed || previous.pantry.isFailed else { return nil }
      reused = previous
    } else {
      reused = nil
    }

    let fridge = await result(for: fridgePhotos, reusing: reused?.fridge, scan: scan)
    let pantry = await result(for: pantryPhotos, reusing: reused?.pantry, scan: scan)
    return OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id),
      pantryPhotoIDs: pantryPhotos.map(\.id),
      fridge: fridge,
      pantry: pantry
    )
  }

  private static func result(
    for photos: [FLCapturedPhoto],
    reusing previous: OnboardingKitchenScanResult?,
    scan: ([ScanInput]) async throws -> [Detection]
  ) async -> OnboardingKitchenScanResult {
    if photos.isEmpty { return .notCaptured }
    if let previous, !previous.isFailed { return previous }

    let inputs = OnboardingKitchenReview.scanInputs(for: photos)
    // Photos that can't become scan input were never looked at; "nothing found" would be untrue.
    guard !inputs.isEmpty else { return .failed }
    do {
      return .scanned(try await scan(inputs))
    } catch {
      return .failed
    }
  }
}
