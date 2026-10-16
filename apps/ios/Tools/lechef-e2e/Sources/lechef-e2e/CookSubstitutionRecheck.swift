import Foundation

/// The allergen re-check a substitution receipt carries, in the receipt
/// contract's shape (`docs/spec/lechef/contracts/receipt.schema.json`:
/// `allergenRecheck` — `verdict` | `eaters` | optional `blockedPath`).
///
/// The verdicts are the safety gate's outcomes, not booleans:
/// - `verified` / `plausible` — the substitute screened clean against a known
///   household composition (plausible when the reviewed pair's evidence verdict
///   is only plausible). The swap may execute.
/// - `unsupported` — the household composition is known and refuses the
///   substitute; `blockedPath` names the blocked allergen path, e.g.
///   "Contains wheat via soy sauce".
/// - `unknown` — the composition could not be settled (no reviewed table entry,
///   an unreadable household profile, missing vocabulary). The swap refuses
///   with a blocked path that says the composition is unknown — the honest
///   audit shape; a recheck that did not run never reads as a pass (LeChef §7).
///
/// `eaters` lists who was screened: the cook session's eaters when it has them,
/// else the unnamed household. The canonical JSON uses the key order of
/// `docs/spec/lechef/contracts/examples/receipt-executed.json` — verdict,
/// eaters, blockedPath — and is the exact string the receipt embeds.
public struct CookSubstitutionRecheck: Equatable, Sendable {
  public enum Verdict: String, Sendable, CaseIterable {
    case verified
    case plausible
    case unknown
    case unsupported
  }

  public let verdict: Verdict
  public let eaters: [String]
  public let blockedPath: String?

  public init(verdict: Verdict, eaters: [String], blockedPath: String?) {
    self.verdict = verdict
    self.eaters = eaters
    self.blockedPath = blockedPath
  }

  /// A clean screen against a known household composition: nothing blocked.
  public static func verified(eaters: [String]) -> Self {
    CookSubstitutionRecheck(verdict: .verified, eaters: eaters, blockedPath: nil)
  }

  /// The recheck could not settle the substitute's composition. `because`
  /// appends the reason when the caller knows it; the blocked path always says
  /// the composition is unknown, never invents a pass.
  public static func unknownComposition(eaters: [String], because reason: String? = nil) -> Self {
    CookSubstitutionRecheck(
      verdict: .unknown, eaters: eaters,
      blockedPath: reason.map { "composition unknown: \($0)" } ?? "composition unknown")
  }

  /// `true` when the receipt's swap may execute: a clean screen against a known
  /// composition. `unknown` and `unsupported` both refuse — fail closed.
  public var allowsSwap: Bool { verdict == .verified || verdict == .plausible }

  /// The bytes the receipt embeds verbatim — the phone's own canonical JSON
  /// form: key order verdict, eaters, blockedPath (the contract example's),
  /// `blockedPath` always present, `null` when nothing blocked. Eaters keep the
  /// caller's order; the caller passes a stable order, this type does not sort.
  public var canonicalJSON: String {
    let eatersJSON = eaters.map(Self.escaped).joined(separator: ",")
    return
      "{\"verdict\":\(Self.escaped(verdict.rawValue)),\"eaters\":[\(eatersJSON)],\"blockedPath\":\(blockedPath.map { Self.escaped($0) } ?? "null")}"
  }

  /// JSON string escaping through JSONEncoder — the same mechanism the live
  /// protocol frames use, so a quote in a name cannot break the receipt bytes.
  private static func escaped(_ value: String) -> String {
    let data = try? JSONEncoder().encode([value])
    guard let data, let encoded = String(data: data, encoding: .utf8) else {
      // JSONEncoder cannot fail on a [String]; the fallback keeps the type
      // non-failable.
      return "\"\""
    }
    return String(encoded.dropFirst().dropLast())
  }
}
