import Foundation

/// One resolved item handed to the committer. Identity and grams are both set — the
/// coordinator never commits an unresolved draft.
public struct BarcodeCommitItem: Sendable, Equatable {
  public let ingredientId: Int64
  public let quantityGrams: Double
  /// True when grams came from explicit package mass; false when the user entered them.
  public let isMeasured: Bool
  public let confidence: Double

  public init(ingredientId: Int64, quantityGrams: Double, isMeasured: Bool, confidence: Double) {
    self.ingredientId = ingredientId
    self.quantityGrams = quantityGrams
    self.isMeasured = isMeasured
    self.confidence = confidence
  }
}

/// The commit seam. The app implements this over `InventoryIntakeService.ingestGrocerySession`
/// (PR42's session commit path); tests use counting fakes. Implementations must treat the
/// same `sourceRef` as idempotent — a duplicate commit is a no-op, not a second copy.
public protocol BarcodeSessionCommitting: Sendable {
  func commit(items: [BarcodeCommitItem], sourceRef: String) async throws -> Int
}

/// One barcode draft in the intake session: a scanned or entered GTIN, its looked-up
/// product (when one was found), its explicit package mass (when one exists), and its
/// catalog binding (which may be ambiguous or unbound).
public struct BarcodeDraftItem: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let gtin: ValidatedGTIN
  public let productName: String?
  public let brands: String?
  /// Identity, `nil` while ambiguous or unbound.
  public var ingredientId: Int64?
  public var confidence: Double
  /// Amount from explicit package mass, or set by the user; `nil` stays unknown.
  public var amountGrams: Double?
  /// True when `amountGrams` came from package mass; false once the user set it.
  public var isMeasured: Bool
  public var binding: CatalogBinding
  public var candidates: [CatalogCandidate]
  public var evidenceSummary: String?
  public var isStale: Bool

  public init(
    id: UUID = UUID(),
    gtin: ValidatedGTIN,
    productName: String?,
    brands: String?,
    ingredientId: Int64?,
    confidence: Double,
    amountGrams: Double?,
    isMeasured: Bool,
    binding: CatalogBinding,
    candidates: [CatalogCandidate],
    evidenceSummary: String?,
    isStale: Bool
  ) {
    self.id = id
    self.gtin = gtin
    self.productName = productName
    self.brands = brands
    self.ingredientId = ingredientId
    self.confidence = confidence
    self.amountGrams = amountGrams
    self.isMeasured = isMeasured
    self.binding = binding
    self.candidates = candidates
    self.evidenceSummary = evidenceSummary
    self.isStale = isStale
  }

  /// What the review shows for this line.
  public var title: String {
    if let productName, !productName.isEmpty { return productName }
    return "GTIN \(gtin.canonicalGTIN14)"
  }

  public var isResolvedForCommit: Bool {
    ingredientId != nil && amountGrams != nil && (amountGrams ?? 0) > 0
  }
}

/// Stable session source refs for barcode intake. Created once per session and reused
/// across retries, so the intake service's source-ref dedupe makes double commits and
/// retries idempotent.
public enum BarcodeSessionRefs {
  public static func newSourceRef() -> String {
    "barcode_update_\(UUID().uuidString)"
  }
}

/// Drives one barcode intake session: accept scans or manual GTIN entry, dedupe repeated
/// scans to one draft, build drafts from explicit evidence only, and commit once —
/// retry-safe under the session source ref.
///
/// Foundation-only and @MainActor: the SwiftUI screen wraps it, and the Linux test suite
/// drives it against fakes. The view mirrors `drafts` into its own state after each call.
@MainActor
public final class BarcodeIntakeCoordinator {
  public enum ScanOutcome: Sendable, Equatable {
    case added(UUID)
    /// Same GTIN (canonical form) was already accepted this session — one draft.
    case duplicate(UUID)
    case invalidGTIN(GTINValidationError)
    case lookupFailed(String)
    case cancelled
  }

  public enum CommitOutcome: Sendable, Equatable {
    case committed(Int)
    case nothingToCommit
    /// Already committed this session; no second committer call was made.
    case alreadyCommitted
    /// The session was cancelled; nothing is ever committed after cancel.
    case cancelled
    case failed(String)
  }

  public private(set) var drafts: [BarcodeDraftItem] = []
  /// Stable across the session: every commit attempt (including retries after failure)
  /// carries this ref.
  public let sourceRef: String

  private let lookup: BarcodeProductLookup
  private let resolver: BarcodeCatalogResolver
  private let committer: BarcodeSessionCommitting
  private var hasCommitted = false
  private var isCancelled = false

  public init(
    lookup: BarcodeProductLookup,
    resolver: BarcodeCatalogResolver,
    committer: BarcodeSessionCommitting,
    sourceRef: String = BarcodeSessionRefs.newSourceRef()
  ) {
    self.lookup = lookup
    self.resolver = resolver
    self.committer = committer
    self.sourceRef = sourceRef
  }

  /// Accepts a scanned or manually entered GTIN. Duplicates (same canonical GTIN-14) do
  /// not create a second draft and do not re-lookup.
  public func accept(gtin raw: String) async -> ScanOutcome {
    if isCancelled { return .cancelled }

    let validated: ValidatedGTIN
    do {
      validated = try GTINValidator.validate(raw)
    } catch let error as GTINValidationError {
      return .invalidGTIN(error)
    } catch {
      return .lookupFailed(String(describing: error))
    }

    if let existing = drafts.first(where: { $0.gtin.canonicalGTIN14 == validated.canonicalGTIN14 }) {
      return .duplicate(existing.id)
    }

    let outcome: BarcodeLookupOutcome
    do {
      outcome = try await lookup.lookup(gtin: validated)
    } catch {
      return .lookupFailed(String(describing: error))
    }

    drafts.append(Self.makeDraft(gtin: validated, outcome: outcome, resolver: resolver))
    return .added(drafts.last!.id)
  }

  /// The user set the amount by hand (or cleared it back to unknown).
  public func setAmount(_ grams: Double?, for draftID: UUID) {
    guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
    drafts[index].amountGrams = grams
    drafts[index].isMeasured = false
  }

  /// The user resolved ambiguity (or gave an unbound product an identity) by picking.
  public func pickIdentity(_ candidate: CatalogCandidate, for draftID: UUID) {
    guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
    drafts[index].ingredientId = candidate.id
    drafts[index].confidence = 1.0
    drafts[index].binding = .bound(id: candidate.id, name: candidate.name, score: candidate.score)
    drafts[index].candidates.removeAll { $0.id == candidate.id }
  }

  public func removeDraft(id: UUID) {
    drafts.removeAll { $0.id == id }
  }

  /// Cancelled capture: drafts are dropped and nothing can be committed afterwards.
  public func cancel() {
    isCancelled = true
    drafts = []
  }

  /// Commits every resolved draft. Successful commit latches: later calls return
  /// `.alreadyCommitted` without touching the committer. A failed commit can be retried
  /// with the same source ref — the intake service dedupes by ref.
  public func commitAll() async -> CommitOutcome {
    if isCancelled { return .cancelled }
    if hasCommitted { return .alreadyCommitted }

    let resolved = drafts.filter(\.isResolvedForCommit)
    guard !resolved.isEmpty else { return .nothingToCommit }

    let items = resolved.map { draft in
      BarcodeCommitItem(
        ingredientId: draft.ingredientId!,
        quantityGrams: draft.amountGrams!,
        isMeasured: draft.isMeasured,
        confidence: draft.confidence
      )
    }

    do {
      let lots = try await committer.commit(items: items, sourceRef: sourceRef)
      hasCommitted = true
      return .committed(lots)
    } catch {
      return .failed(String(describing: error))
    }
  }

  // MARK: - Draft building

  /// Builds a draft from a lookup outcome. Mass comes only from explicit package mass
  /// (`PackageMassParser`); identity comes only from the catalog binding — an ambiguous
  /// or unbound product stays that way for the user to resolve.
  static func makeDraft(
    gtin: ValidatedGTIN,
    outcome: BarcodeLookupOutcome,
    resolver: BarcodeCatalogResolver
  ) -> BarcodeDraftItem {
    switch outcome {
    case .fresh(let product):
      return draft(from: product, isStale: false, gtin: gtin, resolver: resolver)
    case .stale(let product):
      return draft(from: product, isStale: true, gtin: gtin, resolver: resolver)
    case .miss:
      let candidates = resolver.candidates(for: nil, brands: nil)
      return BarcodeDraftItem(
        gtin: gtin,
        productName: nil,
        brands: nil,
        ingredientId: nil,
        confidence: 0.5,
        amountGrams: nil,
        isMeasured: false,
        binding: CatalogBinder.bind(candidates),
        candidates: candidates,
        evidenceSummary: nil,
        isStale: false
      )
    }
  }

  private static func draft(
    from product: BarcodeProduct,
    isStale: Bool,
    gtin: ValidatedGTIN,
    resolver: BarcodeCatalogResolver
  ) -> BarcodeDraftItem {
    let candidates = resolver.candidates(for: product.productName, brands: product.brands)
    let binding = CatalogBinder.bind(candidates)
    let mass = PackageMassParser.mass(in: product.quantityText)

    let boundIngredient: (id: Int64, score: Double)? = {
      switch binding {
      case .bound(let id, _, let score): return (id, score)
      case .ambiguous, .unbound: return nil
      }
    }()

    return BarcodeDraftItem(
      gtin: gtin,
      productName: product.productName,
      brands: product.brands,
      ingredientId: boundIngredient?.id,
      confidence: boundIngredient?.score ?? 0.5,
      amountGrams: mass.grams,
      isMeasured: mass.grams != nil,
      binding: binding,
      candidates: candidates,
      evidenceSummary: mass.rawText,
      isStale: isStale
    )
  }
}
