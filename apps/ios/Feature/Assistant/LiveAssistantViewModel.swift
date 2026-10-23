import FLFeatureLogic
import Foundation
import SwiftUI

@MainActor
final class LiveAssistantViewModel: ObservableObject {
  enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
  }

  struct StatusCardModel: Equatable {
    let eyebrow: String
    let title: String
    let message: String
    let showsRetry: Bool
  }

  // MARK: - Connection & Transcript

  @Published var connectionState: ConnectionState = .idle
  @Published var transcript: [LiveAssistantTranscriptEntry] = []
  @Published var composerText = ""
  @Published var isListening = false
  @Published var cameraPermissionStatus: AppPermissionStatus = .notDetermined
  @Published var microphonePermissionStatus: AppPermissionStatus = .notDetermined
  @Published var latestAssistantText = ""

  // MARK: - Floating Bubble

  @Published var showBubble = false
  @Published var bubbleText = ""

  // MARK: - Recipe Step Navigation

  @Published var currentStepIndex: Int = 0
  @Published var completedSteps: Set<Int> = []

  let recipeContext: LiveAssistantRecipeContext
  let captureCoordinator = LiveAssistantCaptureCoordinator()
  /// Parsed once at init with the same parser the offline cooking guide uses, so the live
  /// panel never shows a `Source: …` URL as step 1 or repeats the recipe's own numbering.
  private let parsedGuide: CookingGuideSteps

  var instructionSteps: [String] {
    parsedGuide.steps
  }

  /// Where the recipe came from, kept outside the step count like the cooking guide.
  var recipeAttribution: RecipeAttribution? {
    parsedGuide.attribution
  }

  var totalSteps: Int { instructionSteps.count }

  /// False when there are no steps: an empty or attribution-only recipe is not "on the
  /// last step", and navigation must not treat index 0 as a final step.
  var isOnLastStep: Bool {
    totalSteps > 0 && currentStepIndex >= totalSteps - 1
  }

  var stepProgress: Double {
    guard totalSteps > 0 else { return 0 }
    return Double(currentStepIndex + 1) / Double(totalSteps)
  }

  var isConnected: Bool {
    if case .connected = connectionState {
      return true
    }
    return false
  }

  var canUseMicrophone: Bool {
    isConnected && microphonePermissionStatus.isAuthorizedLike
  }

  var canUseComposer: Bool {
    isConnected
  }

  var statusCard: StatusCardModel? {
    if !cameraPermissionStatus.isAuthorizedLike {
      return StatusCardModel(
        eyebrow: "Camera Needed",
        title: "Give Le Chef a view of your prep area",
        message:
          "The live cook flow is camera-first. Enable camera access so the preview fills the screen and Gemini can stay grounded to what you are making.",
        showsRetry: true
      )
    }

    if !microphonePermissionStatus.isAuthorizedLike {
      return StatusCardModel(
        eyebrow: "Microphone Needed",
        title: "Voice guidance is ready when audio access is on",
        message:
          "You can still read the current step, but voice control stays disabled until microphone access is enabled.",
        showsRetry: true
      )
    }

    guard baseURL != nil else {
      return StatusCardModel(
        eyebrow: "Backend Setup",
        title: "Le Chef is not connected yet",
        message:
          "Set GEMINI_BACKEND_BASE_URL to your Cloud Run or local bridge so the live camera session can connect.",
        showsRetry: true
      )
    }

    switch connectionState {
    case .idle:
      return StatusCardModel(
        eyebrow: "Starting",
        title: "Opening your live cook session",
        message: "Le Chef is preparing the camera and live connection.",
        showsRetry: false
      )
    case .connecting:
      return StatusCardModel(
        eyebrow: "Connecting",
        title: "Reaching the live backend",
        message: "Stay here for a moment while the session attaches to your recipe.",
        showsRetry: false
      )
    case .connected:
      return nil
    case .disconnected:
      return StatusCardModel(
        eyebrow: "Disconnected",
        title: "The live session closed",
        message: "Retry to reopen the session without leaving the cook screen.",
        showsRetry: true
      )
    case .failed(let message):
      return StatusCardModel(
        eyebrow: "Connection Issue",
        title: "Le Chef hit a transport error",
        message: message,
        showsRetry: true
      )
    }
  }

  private let client = GeminiLiveSessionClient()
  private let baseURL: URL?
  private var currentAssistantMessageID: UUID?
  private var bubbleDismissTask: Task<Void, Never>?
  private var householdRecheckService: SubstitutionService?
  private var liveRestrictions: [String]?
  private var householdContextRefreshTask: Task<Void, Never>?

  /// The chat surface's own cook session — the executor's target for approved proposals.
  let cookViewModel: CookModeViewModel
  /// One pending card per live proposal; approve/dismiss settles exactly one receipt.
  let proposalCoordinator: LiveProposalCoordinator
  /// Mirrors `proposalCoordinator.cards` for the chat surface.
  @Published var proposalCards: [LiveProposalCard] = []

  init(recipeContext: LiveAssistantRecipeContext) {
    self.recipeContext = recipeContext
    self.parsedGuide = CookingGuideSteps(instructions: recipeContext.instructions)
    let env = ProcessInfo.processInfo.environment["GEMINI_BACKEND_BASE_URL"]
    let plist = Bundle.main.object(forInfoDictionaryKey: "GEMINI_BACKEND_BASE_URL") as? String
    self.baseURL = Self.resolvedBaseURL(env ?? plist)

    // The chat surface's cook session: in-memory, fail-closed on allergen knowledge
    // (unknown blocks, LeChef §7), no meal logging — this is not the persisted cook-mode
    // surface, but proposals still execute against a real session. A catalog recipe
    // runs the packet's structured steps and links the exact (catalogId, revision);
    // legacy recipes cook from the parsed instructions and the integer-id reference.
    var liveDependencies = CookModeViewModel.Dependencies.ephemeral()
    // The fail-closed default: no boolean screen either — swaps refuse as
    // `unknown` until the view installs the household recheck below (LeChef §7).
    liveDependencies.substituteIsAllergen = { _ in nil }
    let catalogContent: CatalogCookContent?
    if let catalogID = recipeContext.catalogID, let revision = recipeContext.catalogRevision,
      let steps = recipeContext.catalogSteps, !steps.isEmpty
    {
      catalogContent = CatalogCookContent(
        catalogId: catalogID, revision: revision, steps: steps)
    } else {
      catalogContent = nil
    }
    let cookViewModel = CookModeViewModel(
      recipe: Recipe(
        id: recipeContext.recipeID,
        title: recipeContext.title,
        timeMinutes: recipeContext.timeMinutes,
        servings: recipeContext.servings,
        instructions: recipeContext.instructions,
        tags: 0,
        source: .bundled,
        createdAt: nil),
      logsMeal: false,
      dependencies: liveDependencies,
      catalog: catalogContent)
    self.cookViewModel = cookViewModel

    let client = self.client
    let coordinator = LiveProposalCoordinator(
      executor: CookProposalExecutor(
        receipts: InMemoryCookReceiptFallback(), target: cookViewModel),
      sendReceiptEnvelope: { envelope in
        Task { await client.sendProposalReceiptEnvelope(envelope) }
      })
    self.proposalCoordinator = coordinator
    coordinator.onCardsChanged = { [weak self] in
      guard let self else { return }
      self.proposalCards = self.proposalCoordinator.cards
    }
    wireCaptureCallbacks()
  }

  /// Wires the shared SubstitutionService onto the chat surface's cook session
  /// (LeChef §7): the household-screened reviewed swaps a proposal may name, as
  /// the cooking guide offers them, and the recheck every swap runs before it
  /// executes. The view calls this before the live session opens in `start()`,
  /// so every proposed swap screens against the household and its receipt
  /// carries the contract's recheck; an unavailable service keeps the fail
  /// closed `unknown` refusal.
  @discardableResult
  func installHouseholdRecheck(from service: SubstitutionService) -> Bool {
    do {
      liveRestrictions = try service.liveSessionRestrictions()
      householdRecheckService = service
    } catch {
      failClosed("Le Chef cannot read your household restrictions, so the live session did not start.")
      return false
    }

    cookViewModel.installSubstitutionOptions { [weak service] ingredientId in
      service?.substitutions(for: ingredientId) ?? []
    }
    cookViewModel.installSubstitutionRecheck {
      [weak service] originalId, substituteId, eaters in
      guard let service else { return .unknownComposition(eaters: eaters) }
      return service.substitutionRecheck(
        for: originalId, substituteId: substituteId, eaters: eaters)
    }
    return true
  }

  // MARK: - Step Navigation

  func goToNextStep() {
    guard currentStepIndex < totalSteps - 1 else { return }
    currentStepIndex += 1
  }

  func goToPreviousStep() {
    guard currentStepIndex > 0 else { return }
    currentStepIndex -= 1
  }

  func toggleStepComplete() {
    if completedSteps.contains(currentStepIndex) {
      completedSteps.remove(currentStepIndex)
    } else {
      completedSteps.insert(currentStepIndex)
    }
  }

  // MARK: - Lifecycle

  func start() async {
    guard let service = householdRecheckService else {
      failClosed("Le Chef cannot verify your household restrictions, so the live session did not start.")
      return
    }
    do {
      // Reconnect must read again: the profile may have changed while disconnected.
      liveRestrictions = try service.liveSessionRestrictions()
    } catch {
      failClosed("Le Chef cannot read your household restrictions, so the live session did not start.")
      return
    }

    cameraPermissionStatus = AppPermissionCenter.status(for: .camera)
    microphonePermissionStatus = AppPermissionCenter.status(for: .microphone)

    if cameraPermissionStatus == .notDetermined {
      _ = await AppPermissionCenter.request(.camera)
      cameraPermissionStatus = AppPermissionCenter.status(for: .camera)
    }
    if microphonePermissionStatus == .notDetermined {
      _ = await AppPermissionCenter.request(.microphone)
      microphonePermissionStatus = AppPermissionCenter.status(for: .microphone)
    }

    if cameraPermissionStatus.isAuthorizedLike {
      captureCoordinator.startCamera()
    }

    guard let baseURL else {
      connectionState = .failed("Set GEMINI_BACKEND_BASE_URL to enable the live assistant.")
      transcript = [
        LiveAssistantTranscriptEntry(
          role: .system,
          text:
            "Live assistant unavailable. Configure the backend URL to connect to Gemini Live on Cloud Run."
        )
      ]
      showBubbleTemporarily(
        "Le Chef is offline. Configure the backend to connect.")
      return
    }

    connectionState = .connecting
    let sessionID = UUID().uuidString
    client.connect(baseURL: baseURL, sessionID: sessionID) { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handle(event: event)
      }
    }
  }

  func stop() {
    householdContextRefreshTask?.cancel()
    householdContextRefreshTask = nil
    captureCoordinator.stopMicrophoneStreaming()
    captureCoordinator.stopCamera()
    client.disconnect()
    isListening = false
    bubbleDismissTask?.cancel()
    if connectionState == .connected || connectionState == .connecting {
      connectionState = .disconnected
    }
  }

  func reconnect() async {
    stop()
    await start()
  }

  func sendComposerText() async {
    guard canUseComposer else { return }
    let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    transcript.append(.init(role: .user, text: trimmed))
    composerText = ""
    await client.sendTextTurn(trimmed)
  }

  func toggleListening() async {
    guard canUseMicrophone else { return }
    if isListening {
      captureCoordinator.stopMicrophoneStreaming()
      isListening = false
      await client.endAudioTurn()
    } else {
      do {
        isListening = true
        await client.beginAudioTurn()
        try captureCoordinator.startMicrophoneStreaming()
      } catch {
        isListening = false
        connectionState = .failed(error.localizedDescription)
      }
    }
  }

  // MARK: - Bubble

  private func failClosed(_ message: String) {
    connectionState = .failed(message)
    transcript = [LiveAssistantTranscriptEntry(role: .system, text: message)]
    showBubbleTemporarily(message)
  }

  private func showBubbleTemporarily(_ text: String) {
    bubbleText = text
    showBubble = true
    bubbleDismissTask?.cancel()
    bubbleDismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled else { return }
      showBubble = false
    }
  }

  // MARK: - Internals

  private func wireCaptureCallbacks() {
    captureCoordinator.onVideoFrame = { [weak self] data in
      Task { @MainActor [weak self] in
        await self?.client.sendImageFrame(data)
      }
    }
    captureCoordinator.onAudioChunk = { [weak self] data, sampleRate in
      Task { @MainActor [weak self] in
        guard let self, self.isListening else { return }
        await self.client.sendAudioChunk(data, sampleRate: sampleRate)
      }
    }
  }

  // MARK: - Bounded snapshot

  private func refreshHouseholdContextIfNeeded() async -> Bool {
    guard let service = householdRecheckService, let previous = liveRestrictions else {
      failClosed("Le Chef cannot verify your household restrictions, so the live session ended.")
      stop()
      return false
    }
    do {
      let current = try service.liveSessionRestrictions()
      guard current != previous else { return true }
      liveRestrictions = current
      let snapshot = Self.boundedSnapshot(from: cookViewModel, recipeContext: recipeContext, restrictions: current)
      await client.sendBoundedSnapshot(payload: snapshot)
      return true
    } catch {
      stop()
      failClosed("Le Chef could not reread your household restrictions, so the live session ended.")
      return false
    }
  }

  private func startHouseholdContextRefresh() {
    householdContextRefreshTask?.cancel()
    householdContextRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled, let self else { return }
        guard self.isConnected else { return }
        guard await self.refreshHouseholdContextIfNeeded() else { return }
      }
    }
  }

  /// The once-per-session bounded snapshot. Its shape is pinned against the recorded
  /// gateway payload by the codec fixtures: session revision, bounded cook-session
  /// fields, and only the current recipe bill when a cook session has one.
  static func boundedSnapshot(
    from cookViewModel: CookModeViewModel, recipeContext: LiveAssistantRecipeContext,
    restrictions: [String] = []
  ) -> [String: Any] {
    var cookSession: [String: Any] = [
      "state": cookViewModel.phase == .idle ? "planning" : "cooking",
      "currentStepIndex": cookViewModel.state.stepIndex ?? 0,
      "eaters": [["name": "you", "restrictions": restrictions]] as [[String: Any]],
      "activeTimers": [] as [[String: Any]],
      "cameraMode": "push-to-look",
    ]
    var recipes: [[String: Any]] = []
    if let ref = cookViewModel.session.recipeRef, ref.id != "-1" {
      cookSession["recipeId"] = ref.id
      recipes = [[
        "id": ref.id,
        "revision": ref.revision,
        "title": recipeContext.title,
        "servings": recipeContext.servings,
        "ingredientBill": recipeContext.ingredients.map { ingredient in
          [
            "ingredientId": ingredient.id,
            "name": ingredient.name,
            "quantity": ingredient.quantityGrams.map {
              ["kind": "known", "value": $0, "unit": "grams"]
            } ?? ["kind": "unknown"]
          ] as [String: Any]
        },
        // Adaptation screening only needs the bill. Full step text stays on the phone.
        "steps": [] as [[String: Any]]
      ]]
    }
    return [
      "revision": cookViewModel.snapshotRevision,
      "pantrySnapshot": [
        "revision": cookViewModel.snapshotRevision,
        "items": [] as [[String: Any]],
      ] as [String: Any],
      "cookSession": cookSession,
      "recipes": recipes,
    ] as [String: Any]
  }

  static func boundedSnapshot(
    from cookViewModel: CookModeViewModel, restrictions: [String] = []
  ) -> [String: Any] {
    var payload = boundedSnapshot(
      from: cookViewModel,
      recipeContext: LiveAssistantRecipeContext(
        recipeID: nil, title: "", timeMinutes: 0, servings: 0, instructions: "", ingredients: []),
      restrictions: restrictions)
    var cookSession = payload["cookSession"] as? [String: Any] ?? [:]
    cookSession.removeValue(forKey: "recipeId")
    payload["cookSession"] = cookSession
    payload["recipes"] = [] as [[String: Any]]
    return payload
  }

  /// The chat surface approved a card: the coordinator executes through the executor's
  /// gates and answers the gateway with exactly one receipt. `now` is the decision time;
  /// the default reads the clock, tests pin it against the proposal's recorded timestamps.
  func approveProposal(_ proposalID: String, now: Date = Date()) {
    proposalCoordinator.approve(proposalID, now: now)
  }

  /// Internal for tests: the view model routes session client events.
  func handle(event: GeminiLiveSessionClient.Event) {
    switch event {
    case .sessionOpened:
      connectionState = .connected
      transcript.append(
        .init(
          role: .system,
          text:
            "Live session ready. Place your phone on a counter stand near your prep area."
        )
      )
      showBubbleTemporarily("Le Chef is ready. Place your phone where I can see your prep area.")
      // The chat surface's cook session runs while the live session is open.
      if cookViewModel.phase == .idle {
        cookViewModel.startOrResume()
      }
      let recipeContext = self.recipeContext
      let snapshot = Self.boundedSnapshot(
        from: cookViewModel, recipeContext: recipeContext, restrictions: liveRestrictions ?? [])
      Task { [weak self, client] in
        await client.sendSessionContext(recipeContext: recipeContext)
        // The bounded snapshot goes up once per session, right after the recipe context.
        await client.sendBoundedSnapshot(payload: snapshot)
        self?.startHouseholdContextRefresh()
        await client.sendTextTurn(
          "I am cooking \(recipeContext.title). Guide me step by step and stay conservative about exact nutrition."
        )
      }
    case .proposalReceived(let proposal):
      proposalCoordinator.received(proposal)
      proposalCards = proposalCoordinator.cards
    case .proposalMalformed:
      transcript.append(
        .init(
          role: .system,
          text:
            "Le Chef tried to propose an action the phone could not verify. It was ignored."
        )
      )
    case .assistantText(let text, let isTurnComplete):
      latestAssistantText = text
      if let currentAssistantMessageID,
        let index = transcript.firstIndex(where: { $0.id == currentAssistantMessageID })
      {
        transcript[index] = LiveAssistantTranscriptEntry(
          id: currentAssistantMessageID, role: .assistant, text: text)
      } else {
        let id = UUID()
        currentAssistantMessageID = id
        transcript.append(.init(id: id, role: .assistant, text: text))
      }

      // Show latest in floating bubble
      showBubbleTemporarily(text)

      if isTurnComplete {
        currentAssistantMessageID = nil
      }
    case .sessionError(let message):
      connectionState = .failed(message)
      transcript.append(.init(role: .system, text: message))
      showBubbleTemporarily(message)
    case .sessionClosed(let reason):
      connectionState = .disconnected
      transcript.append(.init(role: .system, text: reason))
      showBubbleTemporarily(reason)
    }
  }

  private static func resolvedBaseURL(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
    return URL(string: trimmed)
  }
}

extension AppPermissionStatus {
  fileprivate var isAuthorizedLike: Bool {
    self == .authorized || self == .limited
  }
}
