import Foundation

// Profile-basics state and validation core for the settings screen.
//
// Foundation-only by contract: this file is compiled and tested off-platform
// (Linux harness), so it must not import SwiftUI, Combine, UIKit, or GRDB.
// No profile values are logged anywhere in this file.

// MARK: - Draft

/// The editable state of the profile-basics screen.
///
/// - `profile` is the value actually loaded from the repository. Saving
///   rewrites ONLY `displayName` and `age` on this value; goal, daily
///   calories, macro split, dietary restrictions, and allergens always carry
///   over untouched. A failed load never produces a draft, so defaults can
///   never overwrite a real profile.
/// - `displayNameText` and `ageText` are raw text field content, parsed only
///   at validation and commit time.
struct ProfileBasicsDraft: Equatable {
  var profile: HealthProfile
  var displayNameText: String
  var ageText: String
}

// MARK: - Validation

/// Outcome of validating a draft. The display name has no rule; age is the
/// only validated field.
enum ProfileBasicsValidation: Equatable {
  case ok
  case invalid(message: String)
}

// MARK: - Phase

/// Full lifecycle of the flow. The view mirrors this; every phase change is
/// announced through `ProfileBasicsFlow.onPhaseChange`.
enum ProfileBasicsPhase: Equatable {
  /// Fetch in flight (also the initial phase before the first `load()`).
  case loading
  /// Fetch failed; no profile value exists. The only forward path is retry.
  case loadFailed(message: String)
  /// Editable. `validation` resets to `.ok` on every text change and is
  /// rechecked at save time.
  case editing(ProfileBasicsDraft, validation: ProfileBasicsValidation)
  /// Transient while a save attempt validates its draft.
  case validating(ProfileBasicsDraft)
  /// Transient while the repository write is in flight.
  case saving(ProfileBasicsDraft)
  /// Write failed; the draft is retained verbatim for retry.
  case saveFailed(draft: ProfileBasicsDraft, message: String)
  /// Persistence committed exactly once for this flow's lifetime.
  case saved
}

// MARK: - Age parsing

/// Result of interpreting the raw age text.
enum ProfileBasicsAgeParse: Equatable {
  /// Blank or whitespace-only text: age clears to nil on save.
  case blankOptional
  /// A whole number within 13...100.
  case valid(Int)
  /// Malformed or out-of-range input; carries the message shown to the user.
  case invalid(message: String)
}

// MARK: - Core

/// Pure parsing, validation, and commit helpers. No state, no I/O.
enum ProfileBasicsCore {
  /// - Blank or whitespace-only text -> `.blankOptional`.
  /// - `Int(text)` in 13...100 -> `.valid(n)`.
  /// - Parsed but out of range -> `.invalid(message: "Age must be between 13 and 100.")`.
  /// - Malformed ("abc", "1 2") or overflowing ("99999999999999999999") text
  ///   -> `.invalid(message: "Age must be a whole number.")`.
  static func parseAge(_ text: String) -> ProfileBasicsAgeParse {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .blankOptional
    }
    guard let age = Int(text) else {
      return .invalid(message: "Age must be a whole number.")
    }
    guard (13...100).contains(age) else {
      return .invalid(message: "Age must be between 13 and 100.")
    }
    return .valid(age)
  }

  /// Age is the only validated field; any display name string may be saved.
  static func validate(_ draft: ProfileBasicsDraft) -> ProfileBasicsValidation {
    switch parseAge(draft.ageText) {
    case .invalid(let message):
      return .invalid(message: message)
    case .blankOptional, .valid:
      return .ok
    }
  }

  /// The profile to persist: the LOADED value with only `displayName` (trimmed)
  /// and `age` rewritten. Call only after `validate` returned `.ok` — invalid
  /// age text (unreachable through the flow) commits as nil.
  static func committedProfile(from draft: ProfileBasicsDraft) -> HealthProfile {
    var profile = draft.profile
    profile.displayName = draft.displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    if case .valid(let age) = parseAge(draft.ageText) {
      profile.age = age
    } else {
      profile.age = nil
    }
    return profile
  }
}

// MARK: - Flow

/// State machine owning the profile-basics lifecycle: load (with retry), edit,
/// validate, save (with retry), done.
///
/// Threading: a plain class with no isolation attributes — the view drives it
/// from the main thread; the Linux test harness calls it directly. Not
/// thread-safe on its own.
///
/// Reentrancy: `fetchProfile`/`saveProfile` may re-enter the flow's public
/// methods. Every entry point is guarded by the current phase, so a reentrant
/// call during an in-flight load or save is a no-op, `onSaved` fires exactly
/// once per flow lifetime (guard flag), and a stale load result can never land
/// (generation counter). What a closure throws is modeled exactly as failure;
/// returning normally is success.
final class ProfileBasicsFlow {
  private let fetchProfile: () throws -> HealthProfile
  private let saveProfile: (HealthProfile) throws -> Void
  private let onSaved: () -> Void

  /// Fired on every phase transition — a change of value; re-asserting the
  /// current phase never fires. The initial `.loading` precedes any observer
  /// and is therefore never announced.
  var onPhaseChange: ((ProfileBasicsPhase) -> Void)?

  /// Current phase. Starts as `.loading`; the view kicks off `load()`.
  private(set) var phase: ProfileBasicsPhase = .loading

  /// Bumped at the start of each load attempt; a fetch whose generation was
  /// superseded discards its result instead of landing it.
  private var loadGeneration = 0
  /// `load()` runs the initial fetch exactly once; later calls are no-ops
  /// (this is the duplicate-load guard, covering the in-flight `.loading`).
  private var hasStartedLoad = false
  /// `onSaved` fires exactly once per flow lifetime.
  private var hasNotifiedSaved = false

  init(
    fetchProfile: @escaping () throws -> HealthProfile,
    saveProfile: @escaping (HealthProfile) throws -> Void,
    onSaved: @escaping () -> Void
  ) {
    self.fetchProfile = fetchProfile
    self.saveProfile = saveProfile
    self.onSaved = onSaved
  }

  /// Starts the initial load. A no-op once a load has started — the duplicate
  /// guard covers re-entry while `.loading`, including from a reentrant
  /// `fetchProfile` closure.
  func load() {
    guard !hasStartedLoad else { return }
    hasStartedLoad = true
    beginLoad()
  }

  /// Retries the load. Only from `.loadFailed`; genuinely re-calls
  /// `fetchProfile` through the same path as `load()`.
  func retryLoad() {
    guard case .loadFailed = phase else { return }
    beginLoad()
  }

  /// Updates the display name text. Only meaningful in `.editing` and
  /// `.saveFailed`; resets validation to `.ok` (revalidated at save time).
  /// No-op in every other phase.
  func setDisplayNameText(_ text: String) {
    switch phase {
    case .editing(var draft, _):
      draft.displayNameText = text
      transition(to: .editing(draft, validation: .ok))
    case .saveFailed(var draft, let message):
      draft.displayNameText = text
      transition(to: .saveFailed(draft: draft, message: message))
    default:
      break
    }
  }

  /// Updates the age text. Same semantics as `setDisplayNameText(_:)`.
  func setAgeText(_ text: String) {
    switch phase {
    case .editing(var draft, _):
      draft.ageText = text
      transition(to: .editing(draft, validation: .ok))
    case .saveFailed(var draft, let message):
      draft.ageText = text
      transition(to: .saveFailed(draft: draft, message: message))
    default:
      break
    }
  }

  /// Saves the current draft. No-op unless the phase is `.editing` or
  /// `.saveFailed` — this is the duplicate-save guard: save attempts during
  /// `.validating`, `.saving`, or `.saved` do nothing.
  ///
  /// Sequence: `.validating` -> on invalid, back to `.editing` with the
  /// message; on valid, `.saving` then either `.saved` (and `onSaved` exactly
  /// once per flow lifetime) or `.saveFailed` with the draft retained for
  /// retry.
  func save() {
    attemptSave()
  }

  /// Retries the save with the retained draft. Only from `.saveFailed`; shares
  /// the save path with `save()`.
  func retrySave() {
    guard case .saveFailed = phase else { return }
    attemptSave()
  }

  // MARK: - Private

  private func beginLoad() {
    loadGeneration += 1
    let generation = loadGeneration
    transition(to: .loading)
    let result = Result { try fetchProfile() }
    // A stale result — this attempt was superseded by a newer one — never lands.
    guard generation == loadGeneration else { return }
    switch result {
    case .success(let fetched):
      let draft = ProfileBasicsDraft(
        profile: fetched,
        displayNameText: fetched.displayName,
        ageText: fetched.age.map(String.init) ?? "")
      transition(to: .editing(draft, validation: .ok))
    case .failure(let error):
      transition(to: .loadFailed(message: error.localizedDescription))
    }
  }

  /// Single save path for `save()` and `retrySave()`. The phase switch below
  /// is the duplicate-save guard.
  private func attemptSave() {
    let draft: ProfileBasicsDraft
    switch phase {
    case .editing(let editingDraft, _):
      draft = editingDraft
    case .saveFailed(let failedDraft, _):
      draft = failedDraft
    default:
      return
    }

    transition(to: .validating(draft))
    switch ProfileBasicsCore.validate(draft) {
    case .invalid(let message):
      transition(to: .editing(draft, validation: .invalid(message: message)))
      return
    case .ok:
      break
    }

    transition(to: .saving(draft))
    let result = Result { try saveProfile(ProfileBasicsCore.committedProfile(from: draft)) }
    switch result {
    case .success:
      transition(to: .saved)
      notifySavedOnce()
    case .failure(let error):
      transition(to: .saveFailed(draft: draft, message: error.localizedDescription))
    }
  }

  private func notifySavedOnce() {
    guard !hasNotifiedSaved else { return }
    hasNotifiedSaved = true
    onSaved()
  }

  private func transition(to newPhase: ProfileBasicsPhase) {
    guard newPhase != phase else { return }
    phase = newPhase
    onPhaseChange?(newPhase)
  }
}
