import FLFeatureLogic
import Foundation
import Observation

/// What the taste profile screen needs from persistence. `TasteProfileRepository`
/// implements it; tests provide fakes.
protocol TasteProfileServicing: Sendable {
  func loadProfile(now: Date) async throws -> TasteProfilePage
  func markWrong(statementId: String, now: Date) async throws
  func markDontAskAgain(statementId: String, mutedUntil: Date?, now: Date) async throws
  func reopen(statementId: String, now: Date) async throws
}

extension TasteProfileRepository: TasteProfileServicing {}

/// One correctable sentence row on the taste profile screen: the sentence, the evidence
/// it stands on, and the corrections the user can make.
struct TasteProfileRow: Identifiable, Equatable, Sendable {
  let id: String
  let text: String
  let layer: TasteProfileStatementLayer
  let state: TasteProfileStatementState
  /// Evidence counts when the sentence carries them ("4 of the 5 times"); nil for
  /// restriction and stated sentences.
  let numerator: Int?
  let denominator: Int?
  let lastEvidenceAt: Date?
  let mutedUntil: Date?
  let pinnedValue: Double?

  /// "This is wrong" is offered on every layer the user can dispute here. Restrictions are
  /// not one of them. SPEC §4 has them edited only where they are set (Food Preferences in
  /// the app), and `TasteProfileRepository.loadProfile` rebuilds them from `health_profile`
  /// on every load, so a rejection recorded here would come back as active on the next
  /// load. The screen links to Food Preferences for them instead.
  var canMarkWrong: Bool {
    layer != .restriction && (state == .active || state == .confirmed)
  }
  /// "Don't ask again" hides a sentence temporarily; it is a different operation from
  /// rejecting it.
  var canDontAskAgain: Bool { canMarkWrong && layer != .restriction }
  /// Reopen is offered on corrected sentences so a correction can be undone.
  var canReopen: Bool { state == .rejected || state == .muted }
}

/// One section of the profile page, in display order.
struct TasteProfileSection: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case restrictions
    case stated
    case pinned
    case learned
    case corrections
  }

  let id: Kind
  let rows: [TasteProfileRow]
}

/// View model for the taste profile page (docs/spec/taste/SPEC.md §4): sections of
/// sentences with their evidence, plus the correction actions, with loading, empty and
/// error states. Views are the UI slice's concern; this exposes everything the mock
/// needs and no UI.
@Observable
@MainActor
final class TasteProfileViewModel {
  private(set) var sections: [TasteProfileSection] = []
  /// Claims the evidence supports but the display bars hide (thin-evidence,
  /// stale-evidence). Machine-visible for the evidence detail sheet, never rendered on
  /// the main list (docs/spec/taste/SPEC.md §4).
  private(set) var hiddenInsights: [TasteHiddenProfileItem] = []
  private(set) var isLoading = false
  /// False until the first load finishes, so the screen can show loading instead of an
  /// empty page before anything has been read.
  private(set) var hasLoaded = false
  private(set) var errorMessage: String?

  /// How long "Don't ask again" hides a sentence. SPEC §4 makes `mutedUntil` optional and
  /// names no length; 90 days is what `TasteProfileRepository.markDontAskAgain` already
  /// stores when given nil. Passing it from here keeps the length the screen tells the user
  /// equal to the one stored. Nothing measured picked 90 days; it is the existing default.
  nonisolated static let dontAskAgainDuration: TimeInterval = 90 * 86_400

  private let service: TasteProfileServicing
  private let now: @Sendable () -> Date

  init(service: TasteProfileServicing, now: @escaping @Sendable () -> Date = { Date() }) {
    self.service = service
    self.now = now
  }

  var isEmpty: Bool {
    !isLoading && errorMessage == nil && sections.allSatisfy(\.rows.isEmpty)
  }

  /// Loads (or reloads) the profile.
  func load() async {
    isLoading = true
    errorMessage = nil
    defer {
      isLoading = false
      hasLoaded = true
    }
    do {
      let page = try await service.loadProfile(now: now())
      sections = Self.sections(from: page)
      hiddenInsights = page.hidden
    } catch {
      errorMessage = "Couldn't load your taste profile. Try again."
      sections = []
      hiddenInsights = []
    }
  }

  /// "This is wrong": the sentence is removed and never re-learned from the same
  /// evidence.
  func markWrong(_ row: TasteProfileRow) async {
    let at = now()
    await apply { try await self.service.markWrong(statementId: row.id, now: at) }
  }

  /// "Don't ask again": the sentence hides for `dontAskAgainDuration`. Unlike a rejection,
  /// it may return.
  func dontAskAgain(_ row: TasteProfileRow) async {
    let at = now()
    let until = at.addingTimeInterval(Self.dontAskAgainDuration)
    await apply {
      try await self.service.markDontAskAgain(statementId: row.id, mutedUntil: until, now: at)
    }
  }

  /// Reopen: undo a correction; the next recompute re-evaluates the sentence against
  /// the evidence.
  func reopen(_ row: TasteProfileRow) async {
    let at = now()
    await apply { try await self.service.reopen(statementId: row.id, now: at) }
  }

  private func apply(_ operation: @escaping @Sendable () async throws -> Void) async {
    errorMessage = nil
    do {
      try await operation()
      await load()
    } catch {
      errorMessage = "Couldn't apply that. Try again."
    }
  }

  // MARK: - Page mapping

  nonisolated static func sections(from page: TasteProfilePage) -> [TasteProfileSection] {
    let rows = page.statements.map(Self.row(from:))
    func layer(_ kind: TasteProfileStatementLayer) -> [TasteProfileRow] {
      rows.filter { $0.layer == kind }
    }
    let renderedStates: Set<TasteProfileStatementState> = [.active, .confirmed]
    // Muted and pinned rows stay visible in their own sections so reopen is reachable;
    // expired is a hidden state and appears only in hiddenInsights.
    return [
      TasteProfileSection(id: .restrictions, rows: layer(.restriction)),
      TasteProfileSection(id: .stated, rows: layer(.stated)),
      TasteProfileSection(id: .pinned, rows: layer(.pinned)),
      TasteProfileSection(
        id: .learned,
        rows: layer(.inferred).filter { renderedStates.contains($0.state) }),
      // "This is wrong" sentences are kept, struck through, never re-learned; "Don't
      // ask again" sentences show here with a reopen control until they return.
      TasteProfileSection(
        id: .corrections,
        rows: layer(.inferred).filter { $0.state == .rejected || $0.state == .muted }),
    ]
  }

  nonisolated static func row(from statement: TasteProfileStatementValue) -> TasteProfileRow {
    TasteProfileRow(
      id: statement.id,
      text: statement.text,
      layer: statement.layer,
      state: statement.state,
      numerator: statement.numerator,
      denominator: statement.denominator,
      lastEvidenceAt: statement.lastEvidenceAt,
      mutedUntil: statement.mutedUntil,
      pinnedValue: statement.pinnedValue)
  }

  /// The evidence detail sentence: "4 of the 5 recipes you cooked that had it",
  /// rendered from the counts the statement stands on. The profile never states a
  /// number the evidence does not show (docs/spec/taste/SPEC.md §4).
  static func evidenceDetail(for row: TasteProfileRow) -> String? {
    guard let numerator = row.numerator, let denominator = row.denominator else {
      return nil
    }
    return "\(numerator) of \(denominator)"
  }
}
