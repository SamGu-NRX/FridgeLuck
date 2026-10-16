import FLFeatureLogic
import Foundation
import Observation

/// Sign-in state for the community surfaces (community SPEC 6.1, 6.2, §9.2). The Sign in
/// with Apple button and sheet are UI: call `appleRequestNonce()` when building the
/// `ASAuthorization` request — it binds SHA-256 of a fresh raw nonce into the request and
/// remembers the raw nonce — then hand this view model the identity token Apple returns.
/// This type owns everything around that exchange — phases, gates, sign-out, and the
/// twice-confirmed account deletion (SPEC 6.7).
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

  /// The raw nonce whose SHA-256 `appleRequestNonce()` bound into the Apple request;
  /// consumed by the matching `signIn(identityToken:)`.
  private var pendingRawNonce: String?

  public init(service: CommunitySessionService) {
    self.service = service
    account = service.account
    phase = service.account == nil ? .signedOut : .signedIn
  }

  /// Call when building the `ASAuthorizationAppleIDRequest` (SPEC 3.3): mints a fresh raw
  /// nonce, remembers it for `signIn(identityToken:)`, and returns the value to bind into
  /// the request — SHA-256 of the raw nonce, which Apple echoes back inside the identity
  /// token. The raw nonce itself never goes into the Apple request.
  public func appleRequestNonce() -> String {
    let raw = CommunityNonce.generate()
    pendingRawNonce = raw
    return CommunityNonce.authorizationNonce(forRaw: raw)
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

  /// Exchanges the Apple identity token for a session. The raw nonce remembered by
  /// `appleRequestNonce()` rides in the sign-in body — the server hashes it and refuses the
  /// sign-in when the token's `nonce` claim is not its SHA-256 (SPEC 3.3). `birthYear`
  /// carries the 18+ attestation on the first sign-in from a share surface (SPEC 6.2).
  public func signIn(identityToken: String, birthYear: Int? = nil) async {
    phase = .signingIn
    failure = nil
    guard let rawNonce = pendingRawNonce else {
      // No Apple request was built through appleRequestNonce(): a token minted
      // outside the bound flow would be refused by the server, so fail here.
      phase = .signedOut
      failure = .signIn("Start the sign-in from the Sign in with Apple button.")
      return
    }
    pendingRawNonce = nil
    do {
      account = try await service.signIn(identityToken: identityToken, rawNonce: rawNonce, birthYear: birthYear)
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
