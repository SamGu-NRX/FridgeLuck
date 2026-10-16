import Foundation

/// Thread-safe buffer for client events: the client's onEvent is @Sendable and
/// may fire off the main actor; the walk drains it on the main actor.
final class EventBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [GeminiLiveSessionClient.Event] = []

  func push(_ event: GeminiLiveSessionClient.Event) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func drain() -> [GeminiLiveSessionClient.Event] {
    lock.lock()
    defer { lock.unlock() }
    let drained = events
    events = []
    return drained
  }
}

/// The phone side of the end-to-end walk: the pinned production client,
/// coordinator, wire codec, and executor run the scripted cook session over a
/// real WebSocket against the boot's gateway. Every check prints and counts;
/// the process exits non-zero on any failure.
@MainActor
final class Walk {
  private let buffer = EventBuffer()
  private var failures = 0
  private var receiptTasks: [Task<Void, Never>] = []

  private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("walk: [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
  }

  private func drainEvents(timeoutSeconds: Double = 20) async -> GeminiLiveSessionClient.Event? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      for event in buffer.drain() {
        switch event {
        case .assistantText(let text, _):
          print("walk: assistant: \(text)")
        case .sessionOpened, .proposalReceived, .sessionError, .sessionClosed, .proposalMalformed:
          return event
        }
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
  }

  private func awaitProposal(_ label: String) async -> CookActionProposal? {
    guard let event = await drainEvents() else {
      check("proposal arrived for \(label)", false, "timed out")
      return nil
    }
    switch event {
    case .proposalReceived(let proposal):
      return proposal
    case .sessionError(let message):
      check("no session error during \(label)", false, message)
      return nil
    case .proposalMalformed(let detail):
      check("proposal decoded during \(label)", false, detail)
      return nil
    case .sessionClosed(let reason):
      check("session stayed open during \(label)", false, reason)
      return nil
    case .sessionOpened:
      return nil
    case .assistantText:
      return nil
    }
  }

  private func sendTurn(_ text: String) async {
    await client.sendTextTurn(text)
  }

  private func awaitReceipts() async {
    for task in receiptTasks { await task.value }
    receiptTasks.removeAll()
  }

  private var client: GeminiLiveSessionClient!
  private var kitchen: WalkKitchen!
  private var coordinator: LiveProposalCoordinator!

  func run() async -> Int32 {
    let baseURLString = ProcessInfo.processInfo.environment["LECHEF_E2E_URL"] ?? "ws://127.0.0.1:8791"
    guard let baseURL = URL(string: baseURLString) else {
      print("walk: invalid LECHEF_E2E_URL: \(baseURLString)")
      return 2
    }

    client = GeminiLiveSessionClient()
    kitchen = WalkKitchen()
    let receiptLog = WalkReceiptLog()
    coordinator = LiveProposalCoordinator(
      executor: CookProposalExecutor(receipts: receiptLog, target: kitchen)
    ) { [weak self] envelopeText in
      guard let self else { return }
      self.receiptTasks.append(Task { await self.client.sendProposalReceiptEnvelope(envelopeText) })
    }

    // S1 — connect with a client-supplied id the gateway must ignore.
    client.connect(baseURL: baseURL, sessionID: "burst9-e2e-client-id") { [buffer] event in
      buffer.push(event)
    }
    guard let first = await drainEvents(timeoutSeconds: 15) else {
      check("session opened", false, "timed out")
      return 1
    }
    switch first {
    case .sessionOpened(let mintedID):
      check(
        "session_open carries a server-minted id",
        !mintedID.isEmpty && mintedID != "burst9-e2e-client-id",
        "minted \(mintedID)"
      )
    case .sessionError(let message):
      check("session opened", false, message)
      return 1
    default:
      check("session opened", false, "first event was not session_open")
      return 1
    }

    // S2 — the bounded snapshot and one shutter tap (push-to-look).
    await client.sendBoundedSnapshot(
      payload: WalkSnapshots.boundedSnapshot(state: "cooking", stepIndex: 2, revision: 7)
    )
    await client.sendImageFrame(WalkSnapshots.oneByOneJPEG)
    if let event = await drainEvents(timeoutSeconds: 2), case .sessionError(let message) = event {
      check("snapshot and frame accepted", false, message)
    } else {
      check("snapshot and frame accepted", true)
    }

    // S3 — timer proposal: card pending → approved, kitchen timer exists.
    await sendTurn(WalkSnapshots.turnTimer)
    if let proposal = await awaitProposal("timer") {
      var kindOK = false
      var minutes = 0.0
      if case .timerStart(let duration, let label) = proposal.payload {
        kindOK = true
        minutes = duration
        check("timer proposal payload (3 min, noodles)", duration == 3 && label == "noodles")
      }
      check("timer proposal kind", kindOK, "duration=\(minutes)")
      coordinator.received(proposal)
      check("timer card appeared pending", coordinator.cards.count == 1 && coordinator.cards[0].status == .pending)
      coordinator.approve(proposal.proposalID)
      await awaitReceipts()
      check(
        "timer card approved and kitchen timer exists",
        coordinator.cards[0].status == .approved
          && kitchen.timers.contains(where: { $0.seconds == 180 && $0.label == "noodles" })
      )
    }

    // S4 — swap proposal: allergen re-check hard-blocks; the receipt carries
    // the contract-shaped recheck.
    await sendTurn(WalkSnapshots.turnSwap)
    if let proposal = await awaitProposal("swap") {
      var idsOK = false
      if case .swap(let original, let substitute, _) = proposal.payload {
        idsOK = original == 2 && substitute == 9001
      }
      check("swap proposal payload (butter 2 → soy sauce 9001)", idsOK)
      coordinator.received(proposal)
      coordinator.approve(proposal.proposalID)
      await awaitReceipts()
      check(
        "swap card rejected and no substitution applied",
        coordinator.cards[1].status == .rejected && kitchen.substitutionsApplied.isEmpty
          && kitchen.substitutionsBlocked.count == 1
      )
    }

    // S4b — allowed swap proposal: the household screen is clean, the swap
    // executes, and the receipt carries the verified recheck.
    await sendTurn(WalkSnapshots.turnSwapOK)
    if let proposal = await awaitProposal("swap") {
      var idsOK = false
      if case .swap(let original, let substitute, _) = proposal.payload {
        idsOK = original == 2 && substitute == 9002
      }
      check("swap proposal payload (butter 2 -> olive oil 9002)", idsOK)
      coordinator.received(proposal)
      coordinator.approve(proposal.proposalID)
      await awaitReceipts()
      check(
        "swap card approved and substitution applied",
        coordinator.cards[2].status == .approved && kitchen.substitutionsApplied.count == 1
          && kitchen.substitutionsBlocked.count == 1
      )
    }

    // The cook finishes the recipe on the device; the phone re-sends its
    // snapshot (revision 8, done, step 4).
    kitchen.finishRecipeOnDevice(snapshotRevision: 8)
    await client.sendBoundedSnapshot(
      payload: WalkSnapshots.boundedSnapshot(state: "done", stepIndex: kitchen.currentStepIndex, revision: 8)
    )

    // S5 — stale-step proposal: the executor refuses with "no active step".
    await sendTurn(WalkSnapshots.turnStaleStep)
    if let proposal = await awaitProposal("stale step") {
      var kindOK = false
      if case .stepAdvance = proposal.payload { kindOK = true }
      check("stale-step proposal kind", kindOK)
      coordinator.received(proposal)
      coordinator.approve(proposal.proposalID)
      await awaitReceipts()
      check(
        "stale-step card rejected and kitchen unchanged",
        coordinator.cards[3].status == .rejected && kitchen.phase == "done" && kitchen.currentStepIndex == 4
      )
    }

    // S6 — clean disconnect.
    client.disconnect()
    var closedQuietly = true
    if let event = await drainEvents(timeoutSeconds: 5) {
      if case .sessionError(let message) = event {
        check("disconnect without session error", false, message)
        closedQuietly = false
      }
    }
    if closedQuietly { check("disconnect without session error", true) }

    print("walk: \(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")")
    return failures == 0 ? 0 : 1
  }
}

// Top-level code is MainActor-isolated in Swift 6, matching the coordinator
// and executor.
let walk = Walk()
let exitCode = await walk.run()
exit(exitCode)
