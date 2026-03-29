import Foundation
import XCTest

final class CaptureLifecycleRegressionTests: XCTestCase {
  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testCaptureViewUsesUnifiedSessionStartup() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "DesignSystem/Components/FLCaptureView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("@State private var hasStartedSession = false"))
    XCTAssertTrue(source.contains("guard !hasStartedSession else { return }"))
    XCTAssertTrue(source.contains("coordinator.startSessionIfNeeded()"))
    XCTAssertFalse(source.contains("coordinator.configure()"))
    XCTAssertFalse(source.contains("coordinator.startRunning()"))
  }

  func testCaptureViewTearsDownCameraAndGatesShutterOnReadiness() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "DesignSystem/Components/FLCaptureView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains(".onDisappear {"))
    XCTAssertTrue(source.contains("coordinator.shutdownSession()"))
    XCTAssertTrue(source.contains("hasStartedSession = false"))
    XCTAssertTrue(source.contains("|| !coordinator.isCameraReady"))
  }

  func testCoordinatorExposesUnifiedStartupAndShutdownLifecycle() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "DesignSystem/Components/FLCaptureSessionCoordinator.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("private enum SessionState"))
    XCTAssertTrue(source.contains("case idle"))
    XCTAssertTrue(source.contains("case configuring"))
    XCTAssertTrue(source.contains("case running"))
    XCTAssertTrue(source.contains("case failed"))
    XCTAssertTrue(source.contains("func startSessionIfNeeded()"))
    XCTAssertTrue(source.contains("func shutdownSession()"))
    XCTAssertTrue(source.contains("self.captureSession.startRunning()"))
    XCTAssertTrue(source.contains("captureSession.beginConfiguration()"))
    XCTAssertTrue(source.contains("captureSession.commitConfiguration()"))
    XCTAssertTrue(source.contains("static func dismantleUIView"))
    XCTAssertFalse(source.contains("func configure()"))
    XCTAssertFalse(source.contains("func startRunning()"))
    XCTAssertFalse(source.contains("func stopRunning()"))
  }
}
