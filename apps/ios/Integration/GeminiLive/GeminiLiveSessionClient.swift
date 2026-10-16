import FLFeatureLogic
import Foundation

@MainActor
final class GeminiLiveSessionClient: NSObject {
  enum Event: Sendable {
    case sessionOpened(String)
    case assistantText(String, isTurnComplete: Bool)
    /// A `proposal` frame arrived and decoded — the model asked the phone to act.
    case proposalReceived(CookActionProposal)
    /// A `proposal` frame arrived but did not match the contract. The phone never guesses.
    case proposalMalformed(String)
    case sessionError(String)
    case sessionClosed(String)
  }

  private let urlSession: URLSession
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var onEvent: (@Sendable (Event) -> Void)?

  override init() {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: configuration)
    super.init()
  }

  func connect(
    baseURL: URL,
    sessionID: String,
    onEvent: @escaping @Sendable (Event) -> Void
  ) {
    disconnect()
    self.onEvent = onEvent

    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      onEvent(.sessionError("Invalid backend URL."))
      return
    }

    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/live"
    components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]

    guard let url = components.url else {
      onEvent(.sessionError("Could not build live websocket URL."))
      return
    }

    let task = urlSession.webSocketTask(with: url)
    webSocketTask = task
    task.resume()
    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
  }

  // MARK: Session context (SPEC §9.6)

  /// Sends the recipe context the backend's guidance path reads: `instructions` stay a
  /// single string (`StoredRecipeContext.instructions`), cleaned with the same parser the
  /// cooking guide uses so the raw `Source: …` line and the recipe's own numbering never
  /// reach the model; the source rides separately as `sourceAttribution` inside
  /// `selectedRecipe`. No confidence blob rides along — the phone's
  /// `latestConfidence` is client authority and was removed from the protocol.
  func sendSessionContext(recipeContext: LiveAssistantRecipeContext) async {
    await sendEnvelope(
      type: "session_context",
      payload: Self.sessionContextPayload(recipeContext: recipeContext)
    )
  }

  /// Builds the `session_context` recipe payload.
  static func sessionContextPayload(
    recipeContext: LiveAssistantRecipeContext
  ) -> [String: Any] {
    let guide = CookingGuideSteps(instructions: recipeContext.instructions)

    let recipeIngredients = recipeContext.ingredients.map { ingredient -> [String: Any] in
      var payload: [String: Any] = ["name": ingredient.name]
      if let quantityText = ingredient.quantityText {
        payload["quantityText"] = quantityText
      }
      if let quantityGrams = ingredient.quantityGrams {
        payload["quantityGrams"] = quantityGrams
      }
      return payload
    }

    let confirmedIngredients = recipeContext.ingredients.map { ingredient -> [String: Any] in
      var payload: [String: Any] = [
        "name": ingredient.name,
        "confidence": 0.95,
      ]
      if let quantityGrams = ingredient.quantityGrams {
        payload["quantityGrams"] = quantityGrams
      }
      return payload
    }

    var selectedRecipe: [String: Any] = [
      "id": recipeContext.recipeID.map(String.init) ?? recipeContext.id,
      "title": recipeContext.title,
      "timeMinutes": recipeContext.timeMinutes,
      "servings": recipeContext.servings,
      "instructions": guide.steps.joined(separator: "\n"),
      "ingredients": recipeIngredients,
    ]

    if let attribution = guide.attribution {
      var attributionText = "Recipe from \(attribution.label)"
      if let url = attribution.url {
        attributionText += " (\(url.absoluteString))"
      }
      selectedRecipe["sourceAttribution"] = attributionText
    }

    return [
      "selectedRecipe": selectedRecipe,
      "confirmedIngredients": confirmedIngredients,
    ]
  }

  /// Sends the bounded snapshot once per session (SPEC §9.6): the phone's own cook state —
  /// its revision, a bounded pantry summary, and the cook session's shape — as the model's
  /// only view of the kitchen. Never a `tool_response`: that is client authority, and the
  /// gateway rejects one with `client_error` without relaying it to the model.
  func sendBoundedSnapshot(payload: [String: Any]) async {
    await sendEnvelope(type: "session_context", payload: payload)
  }

  /// Sends a receipt envelope's exact bytes. The text comes pre-encoded from
  /// `LiveProposalFrames.receiptEnvelope` so the receipt the gateway sees is the pinned
  /// byte form, not a re-serialized object.
  func sendProposalReceiptEnvelope(_ envelopeText: String) async {
    guard let webSocketTask else { return }
    do {
      try await webSocketTask.send(.string(envelopeText))
    } catch {
      onEvent?(.sessionError(error.localizedDescription))
    }
  }

  func sendTextTurn(_ text: String) async {
    let payload: [String: Any] = [
      "turns": [
        [
          "role": "user",
          "parts": [["text": text]],
        ]
      ],
      "turnComplete": true,
    ]
    await sendEnvelope(type: "client_content", payload: payload)
  }

  func sendImageFrame(_ jpegData: Data) async {
    await sendEnvelope(
      type: "realtime_input",
      payload: [
        "media": [
          "mimeType": "image/jpeg",
          "data": jpegData.base64EncodedString(),
        ]
      ]
    )
  }

  func beginAudioTurn() async {
    await sendEnvelope(
      type: "realtime_input",
      payload: [
        "activityStart": ["type": "user_input"]
      ]
    )
  }

  func sendAudioChunk(_ data: Data, sampleRate: Double) async {
    await sendEnvelope(
      type: "realtime_input",
      payload: [
        "audio": [
          "mimeType": "audio/pcm;rate=\(Int(sampleRate.rounded()))",
          "data": data.base64EncodedString(),
        ]
      ]
    )
  }

  func endAudioTurn() async {
    await sendEnvelope(
      type: "realtime_input",
      payload: [
        "audioStreamEnd": true,
        "activityEnd": ["type": "user_input"],
      ]
    )
  }

  private func sendEnvelope(type: String, payload: [String: Any]) async {
    guard let webSocketTask else { return }
    let envelope: [String: Any] = [
      "type": type,
      "payload": payload,
    ]

    guard
      let data = try? JSONSerialization.data(withJSONObject: envelope),
      let text = String(data: data, encoding: .utf8)
    else {
      onEvent?(.sessionError("Failed to encode websocket payload."))
      return
    }

    do {
      try await webSocketTask.send(.string(text))
    } catch {
      onEvent?(.sessionError(error.localizedDescription))
    }
  }

  private func receiveLoop() async {
    guard let webSocketTask else { return }
    while !Task.isCancelled {
      do {
        let message = try await webSocketTask.receive()
        let text: String
        switch message {
        case .string(let string):
          text = string
        case .data(let data):
          text = String(decoding: data, as: UTF8.self)
        @unknown default:
          continue
        }
        handleIncoming(text)
      } catch {
        if !Task.isCancelled {
          onEvent?(.sessionError(error.localizedDescription))
        }
        break
      }
    }
  }

  private func handleIncoming(_ text: String) {
    guard
      let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else {
      onEvent?(.sessionError("Received invalid websocket message."))
      return
    }

    switch type {
    case "session_open":
      if let sessionID = json["sessionId"] as? String {
        onEvent?(.sessionOpened(sessionID))
      }
    case "proposal":
      // The model's ask: decode against the contract, then hand the typed proposal to
      // the surface. A frame that does not match is reported malformed, never guessed.
      switch LiveProposalFrames.classify(frameType: type, envelopeJSON: data) {
      case .proposal(let proposal):
        onEvent?(.proposalReceived(proposal))
      default:
        onEvent?(.proposalMalformed(text))
      }
    case "session_error", "client_error":
      let message =
        ((json["payload"] as? [String: Any])?["message"] as? String)
        ?? "Unknown live session error."
      onEvent?(.sessionError(message))
    case "session_close":
      let reason = ((json["payload"] as? [String: Any])?["reason"] as? String) ?? "Session closed."
      onEvent?(.sessionClosed(reason))
    case "server_message":
      guard let payload = json["payload"] as? [String: Any] else { return }
      let serverContent = payload["serverContent"] as? [String: Any]
      let modelTurn = serverContent?["modelTurn"] as? [String: Any]
      let parts = modelTurn?["parts"] as? [[String: Any]] ?? []
      let combinedText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let turnComplete = (serverContent?["turnComplete"] as? Bool) ?? false
      if !combinedText.isEmpty {
        onEvent?(.assistantText(combinedText, isTurnComplete: turnComplete))
      }
    default:
      break
    }
  }
}
