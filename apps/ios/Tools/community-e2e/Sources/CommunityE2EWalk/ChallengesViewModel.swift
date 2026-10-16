import Foundation
import Observation

/// The challenge list surface (community SPEC 4, §9.4).
// @Observable (Observation), not Combine: this type also compiles into the Linux
// community-check mirror (SPEC 8.5).
@MainActor
@Observable
public final class ChallengesViewModel {
  public private(set) var challenges: [CommunityChallenge] = []
  public private(set) var loading = false
  public var failure: String?

  private let client: CommunityAPIClient

  public init(client: CommunityAPIClient) {
    self.client = client
  }

  public func load() async {
    loading = true
    defer { loading = false }
    do {
      challenges = try await client.challenges()
      failure = nil
    } catch {
      failure = ChallengeDetailViewModel.failureCopy(error)
    }
  }
}

/// One entry as the detail surface renders it.
public struct ChallengeEntryDisplay: Equatable, Identifiable {
  public let entry: CommunityChallengeEntry
  public let isMine: Bool
  public let isVoted: Bool
  /// nil until voting closes — no live tallies (SPEC 4.3).
  public let visibleVoteCount: Int?

  public var id: String { entry.entryId }
}

/// The challenge detail surface: entry window, anonymous voting, and the no-live-tallies
/// rule (community SPEC 4.2, 4.3, §9.5).
@MainActor
@Observable
public final class ChallengeDetailViewModel {
  public enum Failure: Equatable {
    /// "Entries are closed." (§9.5)
    case entriesClosed
    /// "This recipe changed on the server. Open it and try again." (SPEC 2.2)
    case recipeRevisedOffline
    /// "We can't verify your rights to this recipe anymore." (SPEC 2.3)
    case quarantinedRights
    /// "Voting isn't open yet." (§9.5)
    case voteTooEarly
    /// "Your vote counts tomorrow." — account younger than 24 h (#166, SPEC 4.3)
    case accountTooNew
    /// The blocked cannot vote on your entries (SPEC 6.3).
    case blocked
    /// 429 — slow down.
    case rateLimited
    /// "Couldn't record your vote. It isn't saved yet." (§9.5)
    case message(String)
  }

  public private(set) var detail: CommunityChallengeDetail?
  public private(set) var loading = false
  public var failure: Failure?

  private let client: CommunityAPIClient
  private let session: SessionViewModel
  private let challengeId: String

  public init(client: CommunityAPIClient, session: SessionViewModel, challengeId: String) {
    self.client = client
    self.session = session
    self.challengeId = challengeId
  }

  // MARK: - Derived state

  public var challenge: CommunityChallenge? { detail?.challenge }

  /// Tallies appear only after voting closes (SPEC 4.3).
  public var talliesVisible: Bool {
    challenge.map { CommunityChallengeRules.talliesRevealed(status: $0.status) } ?? false
  }

  /// "Add yours" lives on the entry window (SPEC 4.2).
  public var canEnter: Bool {
    challenge.map { CommunityChallengeRules.entriesOpen(status: $0.status) } ?? false
  }

  public var votingOpen: Bool {
    challenge.map { CommunityChallengeRules.votingOpen(status: $0.status) } ?? false
  }

  /// "When the voting ends, we'll announce the winner." — a closed challenge with zero
  /// qualifying entries (§9.4).
  public var closedButEmpty: Bool {
    challenge?.status == .closed && (detail?.entries.isEmpty ?? false)
  }

  /// "Your vote counts tomorrow." — shown next to the vote control until the gate lifts.
  public var voteCountsTomorrow: Bool {
    session.voteCountsTomorrow()
  }

  public var myEntryId: String? { challenge?.myEntryId }
  public var myVoteEntryId: String? { challenge?.myVoteEntryId }

  public func entries() -> [ChallengeEntryDisplay] {
    guard let detail else { return [] }
    let status = detail.challenge.status
    return detail.entries.map { entry in
      ChallengeEntryDisplay(
        entry: entry,
        isMine: entry.entryId == detail.challenge.myEntryId,
        isVoted: entry.entryId == detail.challenge.myVoteEntryId,
        visibleVoteCount: CommunityChallengeRules.visibleVoteCount(entry.voteCount, status: status))
    }
  }

  // MARK: - Actions

  public func load() async {
    loading = true
    defer { loading = false }
    do {
      detail = try await client.challenge(id: challengeId)
      failure = nil
    } catch {
      // Keep the last good detail on screen when offline; the failure banner names it.
      failure = .message(Self.failureCopy(error))
    }
  }

  /// Enters with a recipe revision (SPEC 4.2). Errors carry the three named states:
  /// window closed, recipe revised elsewhere, rights no longer verifiable.
  public func enter(recipeRef: RecipeRef, note: String?) async {
    do {
      _ = try await client.createEntry(
        challengeId: challengeId,
        CommunityCreateEntryRequest(
          operationId: UUID().uuidString.lowercased(), recipeRef: recipeRef, note: note))
      failure = nil
      await load()
    } catch {
      failure = mapEnterFailure(error)
    }
  }

  /// Casts or moves the single anonymous vote. No confirm dialog; undo is the same gesture
  /// (§9.5). The gate copy shows through `voteCountsTomorrow`; the server still decides.
  public func vote(entryId: String) async {
    do {
      try await client.castVote(
        challengeId: challengeId, CommunityCastVoteRequest(entryId: entryId))
      failure = nil
      await load()
    } catch {
      failure = mapVoteFailure(error)
    }
  }

  public func removeVote() async {
    do {
      try await client.removeVote(challengeId: challengeId)
      failure = nil
      await load()
    } catch {
      failure = mapVoteFailure(error)
    }
  }

  // MARK: - Failure mapping

  private func mapEnterFailure(_ error: Error) -> Failure {
    guard let apiError = error as? CommunityAPIError else {
      return .message(Self.failureCopy(error))
    }
    switch apiError.serverErrorCode {
    case .entriesClosed:
      return .entriesClosed
    case .recipeRevisedOffline:
      return .recipeRevisedOffline
    case .quarantinedRights:
      return .quarantinedRights
    case .personalData:
      return .message("That note isn't allowed. Try again without personal details.")
    default:
      return .message(Self.failureCopy(error))
    }
  }

  private func mapVoteFailure(_ error: Error) -> Failure {
    guard let apiError = error as? CommunityAPIError else {
      return .message(Self.failureCopy(error))
    }
    switch apiError.serverErrorCode {
    case .voteTooEarly:
      return .voteTooEarly
    case .accountTooNew:
      return .accountTooNew
    case .blocked:
      return .blocked
    case .rateLimited:
      return .rateLimited
    default:
      return .message(Self.failureCopy(error))
    }
  }

  static func failureCopy(_ error: Error) -> String {
    if let apiError = error as? CommunityAPIError, let server = apiError.serverError {
      return server.message
    }
    return "Couldn't reach the challenge. Nothing is lost — try again."
  }
}
