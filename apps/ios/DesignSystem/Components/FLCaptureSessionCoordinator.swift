@preconcurrency import AVFoundation
import SwiftUI
import UIKit

final class FLCaptureSessionCoordinator: NSObject, ObservableObject, @unchecked Sendable {
  let captureSession = AVCaptureSession()

  @Published var isCameraReady = false
  @Published var isFlashAvailable = false
  @Published var isFlashOn = false
  @Published var isCapturingPhoto = false

  private let photoOutput = AVCapturePhotoOutput()
  private let sessionQueue = DispatchQueue(label: "samgu.FridgeLuck.fl-capture")
  private var sessionState: SessionState = .idle
  private var sessionHasFlash = false
  private var isCaptureInFlight = false
  private var photoContinuation: CheckedContinuation<UIImage?, Never>?

  private enum SessionState {
    case idle
    case configuring
    case running
    case failed
  }

  private func updatePublishedState(
    cameraReady: Bool,
    flashAvailable: Bool,
    flashOn: Bool,
    isCapturingPhoto: Bool
  ) {
    let applyState = {
      self.isCameraReady = cameraReady
      self.isFlashAvailable = flashAvailable
      self.isFlashOn = flashOn
      self.isCapturingPhoto = isCapturingPhoto
    }

    if Thread.isMainThread {
      applyState()
    } else {
      DispatchQueue.main.sync(execute: applyState)
    }
  }

  // MARK: - Configuration

  func startSessionIfNeeded() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.sessionState == .idle else { return }

      self.sessionState = .configuring

      let hasConfiguredSession = self.configureSession()
      guard hasConfiguredSession else {
        self.sessionState = .failed
        self.updatePublishedState(
          cameraReady: false,
          flashAvailable: false,
          flashOn: false,
          isCapturingPhoto: false
        )
        return
      }

      guard !self.captureSession.isRunning else {
        self.sessionState = .running
        return
      }

      self.captureSession.startRunning()
      self.sessionState = .running
    }
  }

  @discardableResult
  private func configureSession() -> Bool {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = .photo

    var hasConfiguredSession = false
    var hasFlash = false

    defer {
      captureSession.commitConfiguration()

      let isReady = hasConfiguredSession
      let flashAvailable = hasFlash

      self.sessionHasFlash = flashAvailable

      self.updatePublishedState(
        cameraReady: isReady,
        flashAvailable: isReady ? flashAvailable : false,
        flashOn: false,
        isCapturingPhoto: false
      )
    }

    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device),
      captureSession.canAddInput(input)
    else {
      return false
    }

    captureSession.addInput(input)

    guard captureSession.canAddOutput(photoOutput) else { return false }
    captureSession.addOutput(photoOutput)

    hasFlash = device.hasFlash
    hasConfiguredSession = true
    return true
  }

  // MARK: - Session Lifecycle

  func shutdownSession() {
    updatePublishedState(
      cameraReady: false,
      flashAvailable: false,
      flashOn: false,
      isCapturingPhoto: false
    )

    sessionQueue.async { [weak self] in
      guard let self else { return }

      self.photoContinuation?.resume(returning: nil)
      self.photoContinuation = nil
      self.isCaptureInFlight = false
      self.sessionHasFlash = false

      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }

      self.captureSession.beginConfiguration()
      for input in self.captureSession.inputs {
        self.captureSession.removeInput(input)
      }
      for output in self.captureSession.outputs {
        self.captureSession.removeOutput(output)
      }
      self.captureSession.commitConfiguration()

      self.sessionState = .idle

      self.updatePublishedState(
        cameraReady: false,
        flashAvailable: false,
        flashOn: false,
        isCapturingPhoto: false
      )
    }
  }

  // MARK: - Capture

  func capturePhoto(flashRequested: Bool) async -> UIImage? {
    await withCheckedContinuation { continuation in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }
        guard self.sessionState == .running, self.captureSession.isRunning else {
          continuation.resume(returning: nil)
          return
        }
        guard !self.isCaptureInFlight, self.photoContinuation == nil else {
          continuation.resume(returning: nil)
          return
        }

        self.isCaptureInFlight = true
        self.photoContinuation = continuation
        let flashMode: AVCaptureDevice.FlashMode =
          flashRequested && self.sessionHasFlash ? .on : .off

        Task { @MainActor [weak self] in
          self?.isCapturingPhoto = true
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode

        self.photoOutput.capturePhoto(with: settings, delegate: self)
      }
    }
  }

  private func resumePhotoContinuation(with image: UIImage?) {
    photoContinuation?.resume(returning: image)
    photoContinuation = nil
    isCaptureInFlight = false

    Task { @MainActor [weak self] in
      self?.isCapturingPhoto = false
    }
  }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension FLCaptureSessionCoordinator: AVCapturePhotoCaptureDelegate {
  nonisolated func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard error == nil,
        let data = photo.fileDataRepresentation(),
        let image = UIImage(data: data)
      else {
        self.resumePhotoContinuation(with: nil)
        return
      }

      self.resumePhotoContinuation(with: image)
    }
  }
}

// MARK: - Preview View

final class FLCapturePreviewContainer: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

struct FLCapturePreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> FLCapturePreviewContainer {
    let view = FLCapturePreviewContainer()
    view.previewLayer.videoGravity = .resizeAspectFill
    view.previewLayer.session = session
    return view
  }

  func updateUIView(_ uiView: FLCapturePreviewContainer, context: Context) {
    uiView.previewLayer.session = session
  }

  static func dismantleUIView(_ uiView: FLCapturePreviewContainer, coordinator: ()) {
    uiView.previewLayer.session = nil
  }
}
