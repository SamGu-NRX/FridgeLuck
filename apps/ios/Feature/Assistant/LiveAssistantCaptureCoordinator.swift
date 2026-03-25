@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

final class LiveAssistantCaptureCoordinator: NSObject, ObservableObject, @unchecked Sendable {
  let captureSession = AVCaptureSession()

  var onVideoFrame: (@Sendable (Data) -> Void)?
  var onAudioChunk: (@Sendable (Data, Double) -> Void)?

  private let videoOutput = AVCaptureVideoDataOutput()
  private let ciContext = CIContext()
  private let audioEngine = AVAudioEngine()
  private let captureQueue = DispatchQueue(label: "samgu.FridgeLuck.live-camera")
  private var lastFrameSentAt = Date.distantPast
  private var isCameraConfigured = false

  func startCamera() {
    if !isCameraConfigured {
      configureCameraIfNeeded()
    }
    captureQueue.async { [weak self] in
      guard let self else { return }
      guard !self.captureSession.isRunning else { return }
      self.captureSession.startRunning()
    }
  }

  func stopCamera() {
    captureQueue.async { [weak self] in
      guard let self else { return }
      guard self.captureSession.isRunning else { return }
      self.captureSession.stopRunning()
    }
  }

  func startMicrophoneStreaming() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .mixWithOthers])
    try audioSession.setPreferredSampleRate(16_000)
    try audioSession.setActive(true, options: [])

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, format in
      guard let self else { return }
      let data = Self.pcm16Data(from: buffer)
      self.onAudioChunk?(data, format.sampleRate)
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  func stopMicrophoneStreaming() {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
  }

  private func configureCameraIfNeeded() {
    guard !isCameraConfigured else { return }
    captureSession.beginConfiguration()
    captureSession.sessionPreset = .medium

    defer {
      captureSession.commitConfiguration()
      isCameraConfigured = true
    }

    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device),
      captureSession.canAddInput(input)
    else {
      return
    }

    captureSession.addInput(input)

    videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true
    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }
  }

  private static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data {
    let frameCount = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)

    if let int16Data = buffer.int16ChannelData {
      let pointer = int16Data[0]
      return Data(bytes: pointer, count: frameCount * channels * MemoryLayout<Int16>.size)
    }

    guard let floatData = buffer.floatChannelData else { return Data() }
    var samples = [Int16](repeating: 0, count: frameCount)
    let channel = floatData[0]
    for index in 0..<frameCount {
      let sample = max(-1.0, min(channel[index], 1.0))
      samples[index] = Int16(sample * Float(Int16.max))
    }
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }
}

extension LiveAssistantCaptureCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
  nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let now = Date()
    guard now.timeIntervalSince(lastFrameSentAt) >= 1.0 else { return }
    lastFrameSentAt = now

    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)
    guard let data = image.jpegData(compressionQuality: 0.55) else { return }
    onVideoFrame?(data)
  }
}

struct LiveAssistantPreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewContainerView {
    let view = PreviewContainerView()
    view.previewLayer.videoGravity = .resizeAspectFill
    view.previewLayer.session = session
    return view
  }

  func updateUIView(_ uiView: PreviewContainerView, context: Context) {
    uiView.previewLayer.session = session
  }
}

final class PreviewContainerView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}
