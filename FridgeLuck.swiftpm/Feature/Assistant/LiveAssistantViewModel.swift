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

  @Published var connectionState: ConnectionState = .idle
  @Published var transcript: [LiveAssistantTranscriptEntry] = []
  @Published var composerText = ""
  @Published var isListening = false
  @Published var cameraPermissionStatus: AppPermissionStatus = .notDetermined
  @Published var microphonePermissionStatus: AppPermissionStatus = .notDetermined
  @Published var latestAssistantText = ""

  let recipeContext: LiveAssistantRecipeContext
  let captureCoordinator = LiveAssistantCaptureCoordinator()

  private let client = GeminiLiveSessionClient()
  private let baseURL: URL?
  private var currentAssistantMessageID: UUID?

  init(recipeContext: LiveAssistantRecipeContext) {
    self.recipeContext = recipeContext
    let env = ProcessInfo.processInfo.environment["GEMINI_BACKEND_BASE_URL"]
    let plist = Bundle.main.object(forInfoDictionaryKey: "GEMINI_BACKEND_BASE_URL") as? String
    self.baseURL = URL(string: env ?? plist ?? "")
    wireCaptureCallbacks()
  }

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
    if connectionState == .connected || connectionState == .connecting {
      connectionState = .disconnected
    }
  }

  func reconnect() async {
    stop()
    await start()
  }

  func sendComposerText() async {
    let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    transcript.append(.init(role: .user, text: trimmed))
    composerText = ""
    await client.sendTextTurn(trimmed)
  }

  func toggleListening() async {
    guard microphonePermissionStatus.isAuthorizedLike else { return }
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
            "Live session ready. Place your phone on a counter stand near your prep area for the clearest guidance."
        )
      )
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

      if isTurnComplete {
        currentAssistantMessageID = nil
      }
    case .sessionError(let message):
      connectionState = .failed(message)
      transcript.append(.init(role: .system, text: message))
    case .sessionClosed(let reason):
      connectionState = .disconnected
      transcript.append(.init(role: .system, text: reason))
    }
  }
}

extension AppPermissionStatus {
  fileprivate var isAuthorizedLike: Bool {
    self == .authorized || self == .limited
  }
}
