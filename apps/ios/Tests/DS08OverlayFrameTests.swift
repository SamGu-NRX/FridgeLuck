import SwiftUI
import XCTest

@testable import FridgeLuck

/// Behavioral coverage for the scan overlay pin mapping (FLScanPinLayout /
/// FLScanAnnotationOverlay) and the viewfinder bracket geometry (FLViewfinderFrame).
final class DS08OverlayFrameTests: XCTestCase {
  // MARK: - Helpers

  private let frameSize = CGSize(width: 320, height: 240)

  private func detection(label: String, boundingBox: CGRect?) -> Detection {
    Detection(
      ingredientId: 1,
      label: label,
      confidence: 0.9,
      source: .vision,
      originalVisionLabel: label,
      normalizedBoundingBox: boundingBox
    )
  }

  private func points(of path: Path) -> [CGPoint] {
    var collected: [CGPoint] = []
    path.forEach { element in
      switch element {
      case .move(let point): collected.append(point)
      case .line(let point): collected.append(point)
      case .quadCurve(let point, let control): collected.append(contentsOf: [point, control])
      case .curve(let point, let control1, let control2):
        collected.append(contentsOf: [point, control1, control2])
      case .closeSubpath: break
      }
    }
    return collected
  }

  private func boundingExtent(of path: Path) -> (
    minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat
  )? {
    let pathPoints = points(of: path)
    guard let first = pathPoints.first else { return nil }
    var result = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
    for point in pathPoints.dropFirst() {
      result.minX = min(result.minX, point.x)
      result.minY = min(result.minY, point.y)
      result.maxX = max(result.maxX, point.x)
      result.maxY = max(result.maxY, point.y)
    }
    return result
  }

  @MainActor
  private func viewfinderExtent(for alignment: Alignment, in size: CGSize) -> (
    minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat
  )? {
    boundingExtent(of: FLViewfinderFrame().bracketPath(for: alignment, in: size))
  }

  // MARK: - FLViewfinderFrame: bracket corners

  @MainActor
  func testTopLeadingBracketHugsTopLeftCorner() throws {
    let extent = try XCTUnwrap(viewfinderExtent(for: .topLeading, in: frameSize))
    XCTAssertEqual(extent.minX, 0, accuracy: 0.001)
    XCTAssertEqual(extent.minY, 0, accuracy: 0.001)
    XCTAssertEqual(extent.maxX, 32, accuracy: 0.001)
    XCTAssertEqual(extent.maxY, 32, accuracy: 0.001)
  }

  @MainActor
  func testTopTrailingBracketHugsTopRightCorner() throws {
    let extent = try XCTUnwrap(viewfinderExtent(for: .topTrailing, in: frameSize))
    XCTAssertEqual(extent.maxX, 320, accuracy: 0.001)
    XCTAssertEqual(extent.minY, 0, accuracy: 0.001)
    XCTAssertEqual(extent.minX, 288, accuracy: 0.001)
    XCTAssertEqual(extent.maxY, 32, accuracy: 0.001)
  }

  @MainActor
  func testBottomLeadingBracketHugsBottomLeftCorner() throws {
    let extent = try XCTUnwrap(viewfinderExtent(for: .bottomLeading, in: frameSize))
    XCTAssertEqual(extent.minX, 0, accuracy: 0.001)
    XCTAssertEqual(extent.maxY, 240, accuracy: 0.001)
    XCTAssertEqual(extent.maxX, 32, accuracy: 0.001)
    XCTAssertEqual(extent.minY, 208, accuracy: 0.001)
  }

  @MainActor
  func testBottomTrailingBracketHugsBottomRightCorner() throws {
    let extent = try XCTUnwrap(viewfinderExtent(for: .bottomTrailing, in: frameSize))
    XCTAssertEqual(extent.maxX, 320, accuracy: 0.001)
    XCTAssertEqual(extent.maxY, 240, accuracy: 0.001)
    XCTAssertEqual(extent.minX, 288, accuracy: 0.001)
    XCTAssertEqual(extent.minY, 208, accuracy: 0.001)
  }

  @MainActor
  func testAllFourBracketsStayInsideTheFrame() {
    for alignment in [Alignment.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] {
      guard
        let extent = viewfinderExtent(for: alignment, in: frameSize)
      else {
        XCTFail("No path points for \(alignment)")
        continue
      }
      XCTAssertGreaterThanOrEqual(extent.minX, -0.001, "\(alignment) leaks past the left edge")
      XCTAssertGreaterThanOrEqual(extent.minY, -0.001, "\(alignment) leaks past the top edge")
      XCTAssertLessThanOrEqual(
        extent.maxX, frameSize.width + 0.001, "\(alignment) leaks past the right edge")
      XCTAssertLessThanOrEqual(
        extent.maxY, frameSize.height + 0.001, "\(alignment) leaks past the bottom edge")
    }
  }

  @MainActor
  func testTopBracketsMirrorAcrossTheVerticalCenter() throws {
    let leading = try XCTUnwrap(viewfinderExtent(for: .topLeading, in: frameSize))
    let trailing = try XCTUnwrap(viewfinderExtent(for: .topTrailing, in: frameSize))
    XCTAssertEqual(leading.minY, trailing.minY, accuracy: 0.001)
    XCTAssertEqual(leading.maxY, trailing.maxY, accuracy: 0.001)
    XCTAssertEqual(leading.maxX - leading.minX, trailing.maxX - trailing.minX, accuracy: 0.001)
    XCTAssertEqual(leading.minX, 0, accuracy: 0.001)
    XCTAssertEqual(trailing.maxX, frameSize.width, accuracy: 0.001)
  }

  @MainActor
  func testBottomBracketsMirrorAcrossTheVerticalCenter() throws {
    let leading = try XCTUnwrap(viewfinderExtent(for: .bottomLeading, in: frameSize))
    let trailing = try XCTUnwrap(viewfinderExtent(for: .bottomTrailing, in: frameSize))
    XCTAssertEqual(leading.minY, trailing.minY, accuracy: 0.001)
    XCTAssertEqual(leading.maxY, trailing.maxY, accuracy: 0.001)
    XCTAssertEqual(leading.maxX - leading.minX, trailing.maxX - trailing.minX, accuracy: 0.001)
    XCTAssertEqual(leading.minX, 0, accuracy: 0.001)
    XCTAssertEqual(trailing.maxX, frameSize.width, accuracy: 0.001)
  }

  @MainActor
  func testTopLeadingBracketRoundsTheCornerAtRadius4() {
    let pathPoints = points(of: FLViewfinderFrame().bracketPath(for: .topLeading, in: frameSize))
    XCTAssertTrue(
      pathPoints.contains(CGPoint(x: 0, y: 4)),
      "expected the vertical arm to stop at the corner radius")
    XCTAssertTrue(
      pathPoints.contains(CGPoint(x: 4, y: 0)),
      "expected the horizontal arm to start at the corner radius")
  }

  // MARK: - FLViewfinderFrame: degenerate frames

  @MainActor
  func testBracketArmsClampToTinyFrames() {
    let tiny = CGSize(width: 10, height: 10)
    for alignment in [Alignment.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] {
      guard let extent = viewfinderExtent(for: alignment, in: tiny) else {
        XCTFail("No path points for \(alignment)")
        continue
      }
      XCTAssertGreaterThanOrEqual(extent.minX, -0.001, "\(alignment) leaks past the left edge")
      XCTAssertGreaterThanOrEqual(extent.minY, -0.001, "\(alignment) leaks past the top edge")
      XCTAssertLessThanOrEqual(extent.maxX, 10.001, "\(alignment) leaks past the right edge")
      XCTAssertLessThanOrEqual(extent.maxY, 10.001, "\(alignment) leaks past the bottom edge")
    }
  }

  @MainActor
  func testBracketPathForZeroSizeFrameStaysFinite() {
    for alignment in [Alignment.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] {
      let pathPoints = points(of: FLViewfinderFrame().bracketPath(for: alignment, in: .zero))
      for point in pathPoints {
        XCTAssertFalse(point.x.isNaN, "\(alignment) produced NaN x")
        XCTAssertFalse(point.y.isNaN, "\(alignment) produced NaN y")
        XCTAssertGreaterThanOrEqual(point.x, -0.001)
        XCTAssertLessThanOrEqual(point.x, 0.001)
        XCTAssertGreaterThanOrEqual(point.y, -0.001)
        XCTAssertLessThanOrEqual(point.y, 0.001)
      }
    }
  }

  // MARK: - FLScanPinLayout: pin center mapping

  func testPinCenterFlipsVisionVerticalAxisIntoSwiftUIspace() {
    // Vision space has a bottom-left origin: a box centered at y = 0.3 sits at 0.7 from the top.
    let center = FLScanPinLayout.normalizedPinCenter(
      forBoundingBox: CGRect(x: 0.2, y: 0.25, width: 0.2, height: 0.1))
    XCTAssertEqual(center.x, 0.3, accuracy: 0.0001)
    XCTAssertEqual(center.y, 0.7, accuracy: 0.0001)
  }

  func testPinCenterClampsWhenBoundingBoxSitsAboveTheFrame() {
    let center = FLScanPinLayout.normalizedPinCenter(
      forBoundingBox: CGRect(x: 0.0, y: 1.2, width: 0.4, height: 0.6))
    XCTAssertEqual(center.x, 0.2, accuracy: 0.0001)
    XCTAssertEqual(center.y, 0, accuracy: 0.0001)
  }

  func testPinCenterClampsWhenBoundingBoxSitsBelowAndLeftOfFrame() {
    let center = FLScanPinLayout.normalizedPinCenter(
      forBoundingBox: CGRect(x: -0.6, y: -0.4, width: 0.2, height: 0.2))
    XCTAssertEqual(center.x, 0, accuracy: 0.0001)
    XCTAssertEqual(center.y, 1, accuracy: 0.0001)
  }

  func testPinCenterClampsWhenBoundingBoxOverflowsRightEdge() {
    let center = FLScanPinLayout.normalizedPinCenter(
      forBoundingBox: CGRect(x: 0.95, y: 0.4, width: 0.3, height: 0.2))
    XCTAssertEqual(center.x, 1, accuracy: 0.0001)
    XCTAssertEqual(center.y, 0.5, accuracy: 0.0001)
  }

  func testZeroSizeBoundingBoxPlacesPinWithoutNaN() {
    let center = FLScanPinLayout.normalizedPinCenter(
      forBoundingBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    XCTAssertEqual(center.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(center.y, 0.5, accuracy: 0.0001)
    XCTAssertFalse(center.x.isNaN)
    XCTAssertFalse(center.y.isNaN)
  }

  // MARK: - FLScanPinLayout: annotated mapping

  func testAnnotatedDetectionsDropsDetectionsWithoutBoundingBoxes() {
    let annotated = FLScanPinLayout.annotatedDetections([
      detection(label: "no-box", boundingBox: nil),
      detection(label: "egg", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
      detection(label: "also-no-box", boundingBox: nil),
    ])
    XCTAssertEqual(annotated.count, 1)
    XCTAssertEqual(annotated.first?.label, "egg")
  }

  func testAnnotatedDetectionsCapsAtEightPreservingScanOrder() {
    let detections = (0..<10).map { index in
      detection(label: "\(index)", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }
    let annotated = FLScanPinLayout.annotatedDetections(detections)
    XCTAssertEqual(annotated.count, 8)
    XCTAssertEqual(annotated.map(\.label), (0..<8).map { "\($0)" })
  }

  func testAnnotatedDetectionsKeepsScanOrder() {
    let annotated = FLScanPinLayout.annotatedDetections([
      detection(label: "first", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
      detection(label: "second", boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)),
    ])
    XCTAssertEqual(annotated.map(\.label), ["first", "second"])
  }

  // MARK: - FLScanPinLayout: dot and label positions

  func testDotPositionScalesNormalizedCenterIntoContainer() {
    let dot = FLScanPinLayout.dotPosition(
      pinCenter: CGPoint(x: 0.25, y: 0.75), containerSize: frameSize)
    XCTAssertEqual(dot.x, 80, accuracy: 0.001)
    XCTAssertEqual(dot.y, 180, accuracy: 0.001)
  }

  func testDotPositionWithZeroSizeContainerStaysFinite() {
    // Zero-sized frames multiply by zero; no division is involved, so pins stay finite.
    let dot = FLScanPinLayout.dotPosition(
      pinCenter: CGPoint(x: 0.25, y: 0.75), containerSize: .zero)
    XCTAssertEqual(dot.x, 0, accuracy: 0.0001)
    XCTAssertEqual(dot.y, 0, accuracy: 0.0001)
  }

  func testLabelPositionNudgesLeftForDotsOnRightHalf() {
    let pinCenter = CGPoint(x: 0.9, y: 0.5)
    let label = FLScanPinLayout.labelPosition(pinCenter: pinCenter, containerSize: frameSize)
    let dot = FLScanPinLayout.dotPosition(pinCenter: pinCenter, containerSize: frameSize)
    XCTAssertEqual(label.x, dot.x - 56, accuracy: 0.001)
    XCTAssertEqual(label.y, dot.y + 32, accuracy: 0.001)
  }

  func testLabelPositionNudgesRightForDotsOnLeftHalf() {
    let pinCenter = CGPoint(x: 0.1, y: 0.5)
    let label = FLScanPinLayout.labelPosition(pinCenter: pinCenter, containerSize: frameSize)
    let dot = FLScanPinLayout.dotPosition(pinCenter: pinCenter, containerSize: frameSize)
    XCTAssertEqual(label.x, dot.x + 56, accuracy: 0.001)
    XCTAssertEqual(label.y, dot.y + 32, accuracy: 0.001)
  }

  func testLabelPositionNudgesUpForDotsInBottomHalf() {
    let pinCenter = CGPoint(x: 0.5, y: 0.9)
    let label = FLScanPinLayout.labelPosition(pinCenter: pinCenter, containerSize: frameSize)
    let dot = FLScanPinLayout.dotPosition(pinCenter: pinCenter, containerSize: frameSize)
    XCTAssertEqual(label.x, dot.x + 56, accuracy: 0.001)
    XCTAssertEqual(label.y, dot.y - 32, accuracy: 0.001)
  }

  func testLabelPositionStaysInsideFrameForClampedEdgePins() {
    for pinCenter in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] {
      let label = FLScanPinLayout.labelPosition(pinCenter: pinCenter, containerSize: frameSize)
      XCTAssertGreaterThanOrEqual(label.x, 0, "label escaped the left edge at \(pinCenter)")
      XCTAssertLessThanOrEqual(label.x, frameSize.width, "label escaped the right edge at \(pinCenter)")
      XCTAssertGreaterThanOrEqual(label.y, 0, "label escaped the top edge at \(pinCenter)")
      XCTAssertLessThanOrEqual(label.y, frameSize.height, "label escaped the bottom edge at \(pinCenter)")
    }
  }
}
