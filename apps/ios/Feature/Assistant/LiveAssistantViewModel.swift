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

  var instructionSteps: [String] {
    recipeContext.instructions
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var totalSteps: Int { instructionSteps.count }
  var isOnLastStep: Bool { currentStepIndex >= totalSteps - 1 }

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

  init(recipeContext: LiveAssistantRecipeContext) {
    self.recipeContext = recipeContext
    let env = ProcessInfo.processInfo.environment["GEMINI_BACKEND_BASE_URL"]
    let plist = Bundle.main.object(forInfoDictionaryKey: "GEMINI_BACKEND_BASE_URL") as? String
    self.baseURL = Self.resolvedBaseURL(env ?? plist)
    wireCaptureCallbacks()
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

  private func handle(event: GeminiLiveSessionClient.Event) {
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
      Task { [recipeContext] in
        await client.sendSessionContext(recipeContext: recipeContext)
        await client.sendTextTurn(
          "I am cooking \(recipeContext.title). Guide me step by step and stay conservative about exact nutrition."
        )
      }
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
