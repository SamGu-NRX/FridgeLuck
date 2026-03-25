import FLFeatureLogic
import XCTest

@MainActor
final class AppPermissionCenterTests: XCTestCase {
  func testCameraStatusMapping() {
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(
        cameraAvailable: true,
        authorizationState: .authorized
      ),
      .authorized
    )
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(
        cameraAvailable: true,
        authorizationState: .notDetermined
      ),
      .notDetermined
    )
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(
        cameraAvailable: true,
        authorizationState: .denied
      ),
      .denied
    )
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(
        cameraAvailable: true,
        authorizationState: .restricted
      ),
      .restricted
    )
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(
        cameraAvailable: false,
        authorizationState: .authorized
      ),
      .unavailable
    )
  }

  func testMicrophoneStatusMapping() {
    XCTAssertEqual(
      PermissionMapping.mapMicrophoneStatus(.granted),
      .authorized
    )
    XCTAssertEqual(
      PermissionMapping.mapMicrophoneStatus(.denied),
      .denied
    )
    XCTAssertEqual(
      PermissionMapping.mapMicrophoneStatus(.undetermined),
      .notDetermined
    )
  }

  func testPhotoStatusAndRequestMapping() {
    XCTAssertEqual(
      PermissionMapping.mapPhotoStatus(.authorized),
      .authorized
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoStatus(.limited),
      .limited
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoStatus(.denied),
      .denied
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoStatus(.restricted),
      .restricted
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoStatus(.notDetermined),
      .notDetermined
    )

    XCTAssertEqual(
      PermissionMapping.mapPhotoRequestResult(.authorized),
      .granted
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoRequestResult(.limited),
      .limited
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoRequestResult(.denied),
      .denied
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoRequestResult(.restricted),
      .denied
    )
    XCTAssertEqual(
      PermissionMapping.mapPhotoRequestResult(.notDetermined),
      .denied
    )
  }

  func testCanProceedMapping() {
    XCTAssertTrue(PermissionMapping.canProceed(.granted))
    XCTAssertTrue(PermissionMapping.canProceed(.limited))
    XCTAssertFalse(PermissionMapping.canProceed(.denied))
    XCTAssertFalse(PermissionMapping.canProceed(.unavailable))
  }

  func testLiDARCapabilityMapping() {
    XCTAssertEqual(PermissionMapping.mapLiDARAvailability(true), .available)
    XCTAssertEqual(PermissionMapping.mapLiDARAvailability(false), .unavailable)
  }
}
