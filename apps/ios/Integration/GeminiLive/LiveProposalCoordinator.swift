import FLFeatureLogic
import Foundation

/// A proposed action as the chat surface's card list reads it. `pending` until the user
/// acts (or the executor settles it), then the receipt's outcome. `cancelled` and
/// `rejected` receipts both read as `rejected` — from the user's side they are the same
/// "no" — while `expired` stays its own state.
struct LiveProposalCard: Identifiable, Equatable {
  enum Status: Equatable {
    case pending
    case approved
    case rejected
    case expired
  }

  let id: String  // the proposalID — one card per proposal
  let proposal: CookActionProposal
  var status: Status

  /// Kind-derived action name for the card; the rationale carries the model's why.
  var title: String {
    switch proposal.payload {
    case .timerStart: return "Start a timer"
    case .timerAdjust: return "Adjust a timer"
    case .stepAdvance: return "Move to the next step"
    case .inventoryCorrection: return "Correct the pantry"
    case .mealLog: return "Log this meal"
    case .saveNote: return "Save a note"
    case .plan: return "Plan dinners"
    case .swap: return "Swap an ingredient"
    case .adaptation: return "Adapt the recipe"
    }
  }

  var detail: String { proposal.rationale }
}

/// Turns inbound live proposals into cards and the user's card decisions into executed
/// actions plus receipts (SPEC §8, §9.6). The executor owns every gate — dedupe, payload
/// hash, TTL, approval policy — and the coordinator's only policy contribution is the one
/// surface fact: the chat surface records no phone DeviceEvents, so even timer proposals
/// always wait for an explicit card tap here.
///
/// Every decision path sends exactly one `proposal_receipt` envelope through the session
/// client — the bytes the gateway's receipt path and the mirrored fixtures pin.
@MainActor
final class LiveProposalCoordinator {
  private let executor: CookProposalExecutor
  /// Sends the encoded `proposal_receipt` envelope text over the live session.
  private let sendReceiptEnvelope: (String) -> Void
  @Published private(set) var cards: [LiveProposalCard] = []
  /// Fired after every cards mutation so an observing view model can mirror the list.
  var onCardsChanged: (() -> Void)?

  init(
    executor: CookProposalExecutor,
    sendReceiptEnvelope: @escaping (String) -> Void
  ) {
    self.executor = executor
    self.sendReceiptEnvelope = sendReceiptEnvelope
  }

  /// A proposal frame arrived. One card per proposalID; a repeat is ignored (the
  /// executor's dedupe would refuse to act on it anyway).
  func received(_ proposal: CookActionProposal) {
    guard !cards.contains(where: { $0.id == proposal.proposalID }) else { return }
    cards.append(LiveProposalCard(id: proposal.proposalID, proposal: proposal, status: .pending))
    onCardsChanged?()
  }

  /// The user approved the card. At most once per proposal; the executor refuses the rest.
  func approve(_ proposalID: String, now: Date = Date()) {
    process(proposalID: proposalID, decision: .approve, now: now)
  }

  /// The user dismissed the card. Nothing executes; a `cancelled` receipt answers the model.
  func dismiss(_ proposalID: String, now: Date = Date()) {
    process(proposalID: proposalID, decision: .dismiss, now: now)
  }

  private func process(
    proposalID: String, decision: CookProposalExecutor.Decision, now: Date
  ) {
    guard
      let index = cards.firstIndex(where: { $0.id == proposalID }),
      cards[index].status == .pending
    else { return }
    let proposal = cards[index].proposal
    let receipt = executor.process(proposal, decision: decision, deviceEvents: [], now: now)
    sendReceiptEnvelope(LiveProposalFrames.receiptEnvelope(receipt))
    switch receipt.state {
    case .executed: cards[index].status = .approved
    case .rejected, .cancelled: cards[index].status = .rejected
    case .expired: cards[index].status = .expired
    }
    onCardsChanged?()
  }
}
