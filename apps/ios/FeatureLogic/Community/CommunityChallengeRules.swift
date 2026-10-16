import Foundation

/// Client-side voting and window rules for challenges (community SPEC 4.2, 4.3, 6.3).
///
/// The server enforces all of this; these rules keep the UI honest between refreshes and
/// make the states the mock copy names explicit. They never trust client clocks for gating:
/// the phase comes from the server's `status`, not from comparing local `Date()` values to
/// the window fields.
public enum CommunityChallengeRules {
  /// Tallies are revealed only after voting closes (no live tallies, SPEC 4.3).
  public static func talliesRevealed(status: CommunityChallengeStatus) -> Bool {
    status == .closed
  }

  /// The vote count a client may show, or nil while hidden. Defensive against a server
  /// version that leaks a tally early (SPEC 4.3).
  public static func visibleVoteCount(
    _ voteCount: Int?, status: CommunityChallengeStatus
  ) -> Int? {
    talliesRevealed(status: status) ? voteCount : nil
  }

  /// Entries are accepted only while the challenge is `open`.
  public static func entriesOpen(status: CommunityChallengeStatus) -> Bool {
    status == .open
  }

  /// Voting happens in the `voting` phase.
  public static func votingOpen(status: CommunityChallengeStatus) -> Bool {
    status == .voting
  }

  /// May this account's vote count now? Signed-out never; an account whose 24 h age gate
  /// has not lifted (server-set `canVoteAt`) not yet; everyone else yes (SPEC 4.3).
  public static func canVote(account: CommunityAccount?, now: Date) -> Bool {
    guard let account else { return false }
    guard let canVoteAt = account.canVoteDate else { return true }
    return now >= canVoteAt
  }

  /// "Your vote counts tomorrow." — the copy moment when the vote was cast but will not
  /// count until the gate lifts (SPEC 4.3, §9.5).
  public static func voteCountsTomorrow(account: CommunityAccount?, now: Date) -> Bool {
    guard let account, let canVoteAt = account.canVoteDate else { return false }
    return now < canVoteAt
  }
}
