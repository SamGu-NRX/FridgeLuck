import Foundation
import Observation

/// Sign-in state for the community surfaces (community SPEC 6.1, 6.2, §9.2). The Sign in
/// with Apple button and sheet are UI: the `ASAuthorization` request binds a fresh
/// `CommunityNonce.generate()` value and hands this view model the identity token. This type
/// owns everything around that exchange — phases, gates, sign-out, and the twice-confirmed
/// account deletion (SPEC 6.7).
// @Observable (Observation), not Combine: this type also compiles into the Linux
// community-check mirror (SPEC 8.5).
@MainActor
@Observable
public final class SessionViewModel {
  public enum Phase: Equatable {
    case signedOut
    case signingIn
    case signedIn
  }

  public enum Failure: Equatable {
    case signIn(String)
    case deleteAccount(String)
  }

  public private(set) var phase: Phase = .signedOut
  public private(set) var account: CommunityAccount?
  public var failure: Failure?

  private let service: CommunitySessionService

  public init(service: CommunitySessionService) {
    self.service = service
    account = service.account
    phase = service.account == nil ? .signedOut : .signedIn
  }

  /// The 18+ gate the share and vote surfaces read (SPEC 6.2).
  public var isAdult: Bool { account?.isAdult ?? false }

  /// "Your vote counts tomorrow." — the 24 h account-age moment (SPEC 4.3).
  public func voteCountsTomorrow(now: Date = Date()) -> Bool {
    CommunityChallengeRules.voteCountsTomorrow(account: account, now: now)
  }

  /// App relaunch: verify stored tokens and hydrate the account. A dead session family
  /// signs out; a merely offline phone keeps the signed-in phase unknown → signed-out copy
  /// waits for the next refresh, which is what §9.2's failure state covers.
  public func restore() async {
    phase = .signingIn
    if let account = await service.restore() {
      self.account = account
      phase = .signedIn
    } else {
      account = nil
      phase = .signedOut
    }
  }

  /// Exchanges the Apple identity token for a session. `birthYear` carries the 18+
  /// attestation on the first sign-in from a share surface (SPEC 6.2).
  public func signIn(identityToken: String, birthYear: Int? = nil) async {
    phase = .signingIn
    failure = nil
    do {
      account = try await service.signIn(identityToken: identityToken, birthYear: birthYear)
      phase = .signedIn
    } catch {
      phase = .signedOut
      failure = .signIn(Self.signInFailureCopy(error))
    }
  }

  public func signOut() async {
    await service.signOut()
    account = nil
    phase = .signedOut
  }

  /// Account deletion (SPEC 6.7): the sheet confirms twice, then calls this once.
  public func deleteAccount() async {
    do {
      try await service.deleteAccount()
      account = nil
      phase = .signedOut
    } catch {
      failure = .deleteAccount("Your account isn't deleted yet. Try again when you're online.")
    }
  }

  /// Error copy for the sign-in failure state (§9.2): the server's message when it has one.
  static func signInFailureCopy(_ error: Error) -> String {
    if let apiError = error as? CommunityAPIError, let server = apiError.serverError {
      return server.message
    }
    return "Couldn't sign in. Your account is safe — try again."
  }
}
