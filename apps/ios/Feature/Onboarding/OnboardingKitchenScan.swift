import UIKit

/// What recognition returned for one capture step's photos.
enum OnboardingKitchenScanResult {
  case notCaptured
  case scanned(VisionService.ScanResult)
  case failed

  /// Crops where every recognition request failed. `ScanDiagnostics.passErrors` records only
  /// those, so a crop where classification failed but OCR ran doesn't count.
  var unreadCropCount: Int {
    guard case .scanned(let result) = self else { return 0 }
    return result.diagnostics.passErrors.count
  }

  /// Every photo of this section was scanned and read, so food it doesn't show isn't there.
  /// No photos, a failed scan or unread photos say nothing about the section's food.
  var readEveryPhoto: Bool {
    guard case .scanned = self else { return false }
    return unreadCropCount == 0
  }

  /// Retry rescans locations that failed or that have photos (or parts) that were never read.
  var needsRetry: Bool {
    switch self {
    case .notCaptured: return false
    case .failed: return true
    case .scanned: return unreadCropCount > 0
    }
  }

  fileprivate var detections: [Detection] {
    guard case .scanned(let result) = self else { return [] }
    return result.detections
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
  /// The scan read every photo here and recognized nothing.
  case nothingFound
  /// `someUnread` means part of these photos was never read, so the list may be incomplete.
  /// The list may be empty when every item here was also found, with a higher score, in the
  /// other location.
  case items([Detection], someUnread: Bool)

  var detections: [Detection] {
    if case .items(let detections, _) = self { return detections }
    return []
  }
}

enum OnboardingKitchenReviewState {
  /// The user skipped both photo steps.
  case nothingCaptured
  /// Every photo was read and none showed an ingredient.
  case nothingFound
  /// Nothing was found and some photos were never read, so "nothing found" would be untrue.
  case failed
  case review(fridge: OnboardingKitchenSectionContent, pantry: OnboardingKitchenSectionContent)

  /// The detections the review shows, one per ingredient. Empty outside `.review`.
  var detections: [Detection] {
    guard case .review(let fridge, let pantry) = self else { return [] }
    return fridge.detections + pantry.detections
  }
}

/// The user's checkmarks, kept by ingredient for the whole onboarding run rather than with the
/// latest scan, so a failed scan, a rescan or new photos can't reset them.
struct OnboardingKitchenChoices {
  /// What the user tapped: true to keep, false to leave out.
  private var decisions: [Int64: Bool] = [:]
  /// How each ingredient started the first time it was shown: checked only if
  /// `ConfidenceRouter` routed it to `.auto`. Uncertain and possible items wait for a tap.
  private var initialStates: [Int64: Bool] = [:]

  mutating func noteShown(_ detections: [Detection]) {
    for detection in detections where initialStates[detection.ingredientId] == nil {
      initialStates[detection.ingredientId] = ConfidenceRouter.bucket(for: detection) == .auto
    }
  }

  func isSelected(_ ingredientID: Int64) -> Bool {
    decisions[ingredientID] ?? initialStates[ingredientID] ?? false
  }

  mutating func toggle(_ ingredientID: Int64) {
    decisions[ingredientID] = !isSelected(ingredientID)
  }

  func selectedIDs(in detections: [Detection]) -> Set<Int64> {
    Set(detections.map(\.ingredientId).filter(isSelected))
  }

  /// The user unchecked it themselves, as opposed to it never having been checked.
  func hasRejected(_ ingredientID: Int64) -> Bool {
    decisions[ingredientID] == false
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

    let split = sections(fridge: fridge.detections, pantry: pantry.detections)
    if split.fridge.isEmpty && split.pantry.isEmpty {
      return fridge.needsRetry || pantry.needsRetry ? .failed : .nothingFound
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
      for (name, content) in [("fridge", fridge), ("pantry", pantry)] {
        if let notice = unreadNotice(for: content, place: name) { message += " \(notice)" }
      }
      return message
    }
  }

  /// The warning a section shows when some of its photos weren't read, or nil when all were.
  static func unreadNotice(for content: OnboardingKitchenSectionContent, place: String) -> String? {
    switch content {
    case .failed:
      return "Couldn\u{2019}t read your \(place) photos."
    case .items(_, someUnread: true):
      return "Some \(place) photos couldn\u{2019}t be read."
    case .notCaptured, .nothingFound, .items:
      return nil
    }
  }

  /// What VoiceOver announces when a scan starts, with the photo counts so the user knows
  /// what is being read while the placeholder is up.
  static func scanStartedAnnouncement(fridgePhotos: Int, pantryPhotos: Int) -> String {
    func photos(_ count: Int, _ place: String) -> String {
      count == 1 ? "1 \(place) photo" : "\(count) \(place) photos"
    }
    switch (fridgePhotos, pantryPhotos) {
    case (0, 0):
      return "No photos to scan."
    case (0, let pantry):
      return "Scanning \(photos(pantry, "pantry"))\u{2026}"
    case (let fridge, 0):
      return "Scanning \(photos(fridge, "fridge"))\u{2026}"
    case (let fridge, let pantry):
      return "Scanning \(photos(fridge, "fridge")) and \(photos(pantry, "pantry"))\u{2026}"
    }
  }

  /// VoiceOver labels for the review's photo strip, in display order (fridge photos, then
  /// pantry), at most `limit` labels to match the strip's thumbnail cap. Each label names the
  /// photo's place and its slot among that place's photos.
  static func photoStripLabels(fridgeCount: Int, pantryCount: Int, limit: Int = 6) -> [String] {
    let fridge = (0..<max(0, fridgeCount)).prefix(max(0, limit)).map {
      "Fridge photo \($0 + 1) of \(fridgeCount)"
    }
    let pantry = (0..<max(0, pantryCount)).prefix(max(0, limit - fridge.count)).map {
      "Pantry photo \($0 + 1) of \(pantryCount)"
    }
    return fridge + pantry
  }

  /// Built the way `ScanView.processImage()` builds them: the photo's own source, and its
  /// position among this location's photos as the capture index.
  static func scanInputs(for photos: [FLCapturedPhoto]) -> [ScanInput] {
    photos.enumerated().compactMap { index, photo in
      guard let image = photo.image.cgImage else { return nil }
      return ScanInput(image: image, source: photo.source, captureIndex: index)
    }
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
    case .scanned(let scan):
      let someUnread = result.unreadCropCount > 0
      if scan.detections.isEmpty && !someUnread { return .nothingFound }
      return .items(shown, someUnread: someUnread)
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

/// Runs recognition on the onboarding photos, fridge and pantry as separate scans so each item
/// lands in the section of the photo it came from.
@MainActor
enum OnboardingKitchenScanner {
  /// Scans every captured location when the photos are new. When they match `previous`, scans
  /// only locations that need a retry, and only if `retryFailed`. Returns nil when there is
  /// nothing to do or the task was cancelled; a cancelled run starts no further scan.
  static func run(
    fridgePhotos: [FLCapturedPhoto],
    pantryPhotos: [FLCapturedPhoto],
    previous: OnboardingKitchenScanSession?,
    retryFailed: Bool,
    scan: ([ScanInput]) async throws -> VisionService.ScanResult
  ) async -> OnboardingKitchenScanSession? {
    let reused: OnboardingKitchenScanSession?
    if let previous, previous.covers(fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos) {
      guard retryFailed, previous.fridge.needsRetry || previous.pantry.needsRetry else {
        return nil
      }
      reused = previous
    } else {
      reused = nil
    }

    guard
      let fridge = await result(for: fridgePhotos, reusing: reused?.fridge, scan: scan),
      let pantry = await result(for: pantryPhotos, reusing: reused?.pantry, scan: scan)
    else { return nil }

    return OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id),
      pantryPhotoIDs: pantryPhotos.map(\.id),
      fridge: fridge,
      pantry: pantry
    )
  }

  /// Nil when cancelled.
  private static func result(
    for photos: [FLCapturedPhoto],
    reusing previous: OnboardingKitchenScanResult?,
    scan: ([ScanInput]) async throws -> VisionService.ScanResult
  ) async -> OnboardingKitchenScanResult? {
    guard !Task.isCancelled else { return nil }
    if photos.isEmpty { return .notCaptured }
    if let previous, !previous.needsRetry { return previous }

    let inputs = OnboardingKitchenReview.scanInputs(for: photos)
    // Photos that can't become scan input were never looked at; "nothing found" would be untrue.
    guard !inputs.isEmpty else { return .failed }

    let outcome: OnboardingKitchenScanResult
    do {
      outcome = .scanned(try await scan(inputs))
    } catch {
      outcome = .failed
    }
    return Task.isCancelled ? nil : outcome
  }
}

/// What earlier confirmations in this onboarding run put in the Kitchen, and from which
/// section, so a later confirmation can tell which of those its own scan can't speak for.
struct OnboardingKitchenCommitRecord {
  fileprivate(set) var sectionByIngredient: [Int64: InventoryStorageLocation] = [:]
}

/// What the user confirmed: the scan the review showed and their checkmarks at that moment. A
/// save that fails is retried with this, not with whatever the review shows by then, since a
/// late import can publish a new scan with fresh preselections behind the error alert.
struct OnboardingKitchenConfirmation {
  let session: OnboardingKitchenScanSession
  let choices: OnboardingKitchenChoices
}

/// Writes the review into the Kitchen as one intake call, so each confirmation is a single
/// transaction under one session reference for the whole run. Ingredient identity and what was
/// cooked are then shared across fridge and pantry: an item whose higher score moves from one
/// section to the other on a rescan keeps its one lot.
enum OnboardingKitchenIntake {
  /// Returns the record to keep for the next confirmation. Throws without changing the Kitchen.
  static func commit(
    _ confirmation: OnboardingKitchenConfirmation,
    record: OnboardingKitchenCommitRecord,
    sourceRef: String,
    intake: InventoryIntakeService
  ) throws -> OnboardingKitchenCommitRecord {
    let session = confirmation.session
    let choices = confirmation.choices
    guard case .review(let fridge, let pantry) = session.reviewState else { return record }

    var sectionByIngredient: [Int64: InventoryStorageLocation] = [:]
    for detection in fridge.detections { sectionByIngredient[detection.ingredientId] = .fridge }
    for detection in pantry.detections { sectionByIngredient[detection.ingredientId] = .pantry }
    let shown = fridge.detections + pantry.detections
    let selected = choices.selectedIDs(in: shown)

    // Earlier confirmations from a section this scan can't speak for (no photos now, a failed
    // scan, or unread photos) stay as they are, unless the review shows them again (then the
    // user's current choice applies) or the user unchecked them. Removing a section's photos
    // must not empty that part of the Kitchen.
    var silentSections: Set<InventoryStorageLocation> = []
    if !session.fridge.readEveryPhoto { silentSections.insert(.fridge) }
    if !session.pantry.readEveryPhoto { silentSections.insert(.pantry) }
    let preserved = record.sectionByIngredient.filter { ingredientID, section in
      silentSections.contains(section)
        && sectionByIngredient[ingredientID] == nil
        && !choices.hasRejected(ingredientID)
    }

    try intake.ingestConfirmedScan(
      detections: shown.filter { selected.contains($0.ingredientId) },
      confirmedIngredientIDs: selected,
      selectedIngredientByDetection: [:],
      sourceRef: sourceRef,
      location: .photographed(byIngredient: sectionByIngredient),
      preserving: Set(preserved.keys)
    )

    var next = OnboardingKitchenCommitRecord()
    next.sectionByIngredient = preserved.merging(
      sectionByIngredient.filter { selected.contains($0.key) }
    ) { _, current in current }
    return next
  }
}
