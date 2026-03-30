@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import FridgeLuck

final class CaptureLifecycleRegressionTests: XCTestCase {
  func testCapturePhotoReturnsNilWhenSessionIsNotRunning() async {
    let coordinator = FLCaptureSessionCoordinator()

    let image = await coordinator.capturePhoto(flashRequested: false)

    XCTAssertNil(image)
    XCTAssertFalse(coordinator.isCapturingPhoto)
  }

  func testShutdownSessionResetsPublishedCameraState() async throws {
    let coordinator = FLCaptureSessionCoordinator()
    coordinator.isCameraReady = true
    coordinator.isFlashAvailable = true
    coordinator.isFlashOn = true
    coordinator.isCapturingPhoto = true

    coordinator.shutdownSession()
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertFalse(coordinator.isCameraReady)
    XCTAssertFalse(coordinator.isFlashAvailable)
    XCTAssertFalse(coordinator.isFlashOn)
    XCTAssertFalse(coordinator.isCapturingPhoto)
  }

  @MainActor
  func testPreviewDismantleClearsAttachedSession() {
    let session = AVCaptureSession()
    let container = FLCapturePreviewContainer()
    container.previewLayer.session = session

    FLCapturePreviewView.dismantleUIView(container, coordinator: ())

    XCTAssertNil(container.previewLayer.session)
  }
}
