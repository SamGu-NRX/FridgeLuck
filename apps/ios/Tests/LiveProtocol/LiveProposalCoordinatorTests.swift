import FLFeatureLogic
import Foundation
import XCTest

@testable import FridgeLuck

/// The chat surface's proposal path: a proposal becomes one pending card; a card decision
/// executes at most once against the surface's cook session and sends exactly one receipt
/// envelope; expiry and hash mismatch settle without executing (SPEC §8, §9.6).
@MainActor
final class LiveProposalCoordinatorTests: XCTestCase {
  // MARK: Fixtures

  private final class Capture {
    var texts: [String] = []
  }

  private func makeCookViewModel(logsMeal: Bool = false) -> CookModeViewModel {
    var dependencies = CookModeViewModel.Dependencies.ephemeral()
    // The chat surface's fail-closed stance: allergen knowledge is unknown, unknown blocks.
    dependencies.substituteIsAllergen = { _ in nil }
    return CookModeViewModel(
      recipe: Recipe(
        id: 42,
        title: "Udon",
        timeMinutes: 20,
        servings: 2,
        instructions: "1. Boil the water.\n2. Add the noodles.",
        tags: 0,
        source: .bundled,
        createdAt: nil),
      logsMeal: logsMeal,
      dependencies: dependencies)
  }

  private func makeCoordinator(
    _ cookViewModel: CookModeViewModel, sent: Capture
  ) -> LiveProposalCoordinator {
    LiveProposalCoordinator(
      executor: CookProposalExecutor(
        receipts: InMemoryCookReceiptFallback(), target: cookViewModel),
      sendReceiptEnvelope: { sent.texts.append($0) })
  }

  private func proposal(
    _ payload: CookProposalPayload, kind: CookProposalKind,
    createdAt: Date = Date(timeIntervalSince1970: 1_760_547_751),
    ttl: TimeInterval = 300
  ) -> CookActionProposal {
    CookActionProposal(
      proposalID: "prop_test_\(kind.rawValue)",
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(ttl),
      payloadHash: CookProposalWire.payloadHash(of: payload)!,
      kind: kind,
      payload: payload,
      rationale: "The water is boiling.",
      requiredApproval: .explicit)
  }

  // MARK: Cards

  func testProposalBecomesOnePendingCardAndDuplicatesAreIgnored() {
    let sent = Capture()
    let coordinator = makeCoordinator(makeCookViewModel(), sent: sent)
    let stepProposal = proposal(.stepAdvance(stepIndex: 1), kind: .stepAdvance)

    coordinator.received(stepProposal)
    coordinator.received(stepProposal)

    XCTAssertEqual(coordinator.cards.count, 1)
    XCTAssertEqual(coordinator.cards.first?.status, .pending)
    XCTAssertEqual(coordinator.cards.first?.title, "Move to the next step")
    XCTAssertEqual(coordinator.cards.first?.detail, "The water is boiling.")
    XCTAssertTrue(sent.texts.isEmpty, "no receipt until the user acts")
  }

  // MARK: Approval executes on the cook session

  func testApprovedStepAdvanceExecutesOnTheSessionAndSendsItsReceipt() {
    let cookViewModel = makeCookViewModel()
    cookViewModel.startOrResume()
    let sent = Capture()
    let coordinator = makeCoordinator(cookViewModel, sent: sent)
    let stepProposal = proposal(.stepAdvance(stepIndex: 1), kind: .stepAdvance)
    coordinator.received(stepProposal)

    // Decide shortly after the proposal was recorded — inside the TTL — instead of at the
    // runner's wall clock, which is long past the fixture's recorded timestamps.
    let decided = stepProposal.createdAt.addingTimeInterval(10)
    coordinator.approve(stepProposal.proposalID, now: decided)

    XCTAssertEqual(coordinator.cards.first?.status, .approved)
    XCTAssertEqual(sent.texts.count, 1, "exactly one receipt envelope")
    XCTAssertTrue(sent.texts[0].contains("\"type\":\"proposal_receipt\""))
    XCTAssertTrue(sent.texts[0].contains("\"state\":\"executed\""))
    XCTAssertTrue(sent.texts[0].contains("\"snapshotRevision\":\(cookViewModel.snapshotRevision)"))
    XCTAssertEqual(cookViewModel.state.stepIndex, 1, "the approved proposal moved the session on")
    XCTAssertEqual(cookViewModel.state.phase, .cooking)
  }

  func testApprovedMealLogExecutesThroughExplicitApproval() {
    let cookViewModel = makeCookViewModel(logsMeal: true)
    cookViewModel.startOrResume()
    let sent = Capture()
    let coordinator = makeCoordinator(cookViewModel, sent: sent)
    let mealProposal = proposal(
      .mealLog(recipe: CookRecipeRef(source: .catalog, id: "udon", revision: 2)),
      kind: .mealLog)
    coordinator.received(mealProposal)

    coordinator.approve(
      mealProposal.proposalID, now: mealProposal.createdAt.addingTimeInterval(10))

    XCTAssertEqual(coordinator.cards.first?.status, .approved)
    XCTAssertTrue(sent.texts[0].contains("\"state\":\"executed\""))
  }

  // MARK: Dismissal never executes

  func testDismissedProposalSendsACancelledReceiptAndDoesNotAdvance() {
    let cookViewModel = makeCookViewModel()
    cookViewModel.startOrResume()
    let sent = Capture()
    let coordinator = makeCoordinator(cookViewModel, sent: sent)
    let stepProposal = proposal(.stepAdvance(stepIndex: 1), kind: .stepAdvance)
    coordinator.received(stepProposal)

    coordinator.dismiss(
      stepProposal.proposalID, now: stepProposal.createdAt.addingTimeInterval(10))

    XCTAssertEqual(coordinator.cards.first?.status, .rejected)
    XCTAssertTrue(sent.texts[0].contains("\"state\":\"cancelled\""))
    XCTAssertEqual(cookViewModel.state.stepIndex, 0, "nothing executed")
  }

  // MARK: Expiry and at-most-once

  func testExpiredProposalYieldsAnExpiredReceiptAndNeverExecutes() {
    let cookViewModel = makeCookViewModel()
    cookViewModel.startOrResume()
    let sent = Capture()
    let coordinator = makeCoordinator(cookViewModel, sent: sent)
    let stepProposal = proposal(.stepAdvance(stepIndex: 1), kind: .stepAdvance)
    coordinator.received(stepProposal)

    coordinator.approve(stepProposal.proposalID, now: stepProposal.expiresAt.addingTimeInterval(1))

    XCTAssertEqual(coordinator.cards.first?.status, .expired)
    XCTAssertTrue(sent.texts[0].contains("\"state\":\"expired\""))
    XCTAssertEqual(
      cookViewModel.state.stepIndex, 0, "an expired proposal never advances the session")
  }

  func testASecondDecisionOnTheSameCardSendsNoSecondReceipt() {
    let cookViewModel = makeCookViewModel()
    cookViewModel.startOrResume()
    let sent = Capture()
    let coordinator = makeCoordinator(cookViewModel, sent: sent)
    let stepProposal = proposal(.stepAdvance(stepIndex: 1), kind: .stepAdvance)
    coordinator.received(stepProposal)

    let decided = stepProposal.createdAt.addingTimeInterval(10)
    coordinator.approve(stepProposal.proposalID, now: decided)
    coordinator.approve(stepProposal.proposalID, now: decided)
    coordinator.dismiss(stepProposal.proposalID, now: decided)

    XCTAssertEqual(sent.texts.count, 1, "the card is settled; the executor's dedupe holds")
  }

  // MARK: The view model surface

  func testViewModelExposesCardsAndRoutesDecisions() {
    let viewModel = LiveAssistantViewModel(
      recipeContext: LiveAssistantRecipeContext(
        recipeID: 42,
        title: "Udon",
        timeMinutes: 20,
        servings: 2,
        instructions: "1. Boil the water.\n2. Add the noodles.",
        ingredients: []))
    let timerProposal = proposal(
      .timerStart(durationMinutes: 3, label: "Noodles"), kind: .timerStart)

    viewModel.handle(event: .proposalReceived(timerProposal))
    XCTAssertEqual(viewModel.proposalCards.count, 1)
    XCTAssertEqual(viewModel.proposalCards.first?.status, .pending)

    viewModel.approveProposal(
      timerProposal.proposalID, now: timerProposal.createdAt.addingTimeInterval(10))
    XCTAssertEqual(viewModel.proposalCards.first?.status, .approved)
  }

  func testViewModelIgnoresAMalformedProposal() {
    let viewModel = LiveAssistantViewModel(
      recipeContext: LiveAssistantRecipeContext(
        recipeID: 42,
        title: "Udon",
        timeMinutes: 20,
        servings: 2,
        instructions: "1. Boil the water.",
        ingredients: []))

    viewModel.handle(event: .proposalMalformed("not a contract frame"))
    XCTAssertTrue(viewModel.proposalCards.isEmpty)
  }

  func testViewModelBoundedSnapshotCarriesTheSessionShape() {
    let viewModel = LiveAssistantViewModel(
      recipeContext: LiveAssistantRecipeContext(
        recipeID: 42,
        title: "Udon",
        timeMinutes: 20,
        servings: 2,
        instructions: "1. Boil the water.\n2. Add the noodles.",
        ingredients: []))
    viewModel.cookViewModel.startOrResume()

    let snapshot = LiveAssistantViewModel.boundedSnapshot(from: viewModel.cookViewModel)

    XCTAssertTrue(snapshot.keys.contains("revision"))
    XCTAssertTrue(snapshot.keys.contains("pantrySnapshot"))
    XCTAssertTrue(snapshot.keys.contains("cookSession"))
    XCTAssertTrue(snapshot.keys.contains("recipes"))
    let cookSession = snapshot["cookSession"] as? [String: Any]
    XCTAssertEqual(cookSession?["state"] as? String, "cooking")
    XCTAssertEqual(cookSession?["currentStepIndex"] as? Int, 0)
    XCTAssertEqual(cookSession?["cameraMode"] as? String, "push-to-look")
    XCTAssertEqual((snapshot["recipes"] as? [[String: Any]])?.count, 0)
  }
}
