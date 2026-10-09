import FLFeatureLogic
import XCTest

/// Hardening coverage for `PermissionMapping`: pins the complete mapping
/// matrix (every function x every enum case), including the fallback cells
/// `AppPermissionCenterTests` does not cover, and the composed invariants the
/// app's permission UI relies on.
///
/// Key contracts guarded here:
/// - An `unknown` authorization state (e.g. an authorization case added by a
///   future OS) must resolve to `.unavailable` -- never to a status the UI
///   reads as "permission granted".
/// - `cameraAvailable: false` short-circuits the camera mapping regardless of
///   authorization state: the UI must never prompt for absent hardware.
/// - `canProceed` blocks every request outcome except `.granted` and
///   `.limited`.
final class PermissionMappingHardeningTests: XCTestCase {

  // MARK: - Camera

  func testCameraUnavailableShortCircuitsEveryAuthorizationState() {
    // Hardware absence must win over any authorization state, even one that
    // would otherwise read as usable (granted): the app should never offer or
    // prompt for a camera that does not exist.
    let states: [CameraAuthorizationState] = [
      .authorized, .notDetermined, .denied, .restricted, .unknown,
    ]
    for state in states {
      XCTAssertEqual(
        PermissionMapping.mapCameraStatus(cameraAvailable: false, authorizationState: state),
        .unavailable,
        "cameraAvailable=false must short-circuit to .unavailable for \(state)"
      )
    }
  }

  func testCameraAvailableStatusCoversEveryAuthorizationState() {
    let expected: [(CameraAuthorizationState, PermissionStatus)] = [
      (.authorized, .authorized),
      (.notDetermined, .notDetermined),
      (.denied, .denied),
      (.restricted, .restricted),
      // A future/unknown OS authorization case maps to "no usable camera"
      // rather than guessing an authorization state.
      (.unknown, .unavailable),
    ]
    for (state, status) in expected {
      XCTAssertEqual(
        PermissionMapping.mapCameraStatus(cameraAvailable: true, authorizationState: state),
        status,
        "cameraAvailable=true with \(state) must map to \(status)"
      )
    }
  }

  // MARK: - Microphone

  func testMicrophoneStatusCoversEveryAuthorizationState() {
    let expected: [(MicrophoneAuthorizationState, PermissionStatus)] = [
      (.granted, .authorized),
      (.denied, .denied),
      (.undetermined, .notDetermined),
      // Unknown never resolves to a granted-like status.
      (.unknown, .unavailable),
    ]
    for (state, status) in expected {
      XCTAssertEqual(
        PermissionMapping.mapMicrophoneStatus(state),
        status,
        "\(state) must map to \(status)"
      )
    }
  }

  // MARK: - Photo

  func testPhotoStatusCoversEveryAuthorizationState() {
    let expected: [(PhotoAuthorizationState, PermissionStatus)] = [
      (.authorized, .authorized),
      (.limited, .limited),
      (.denied, .denied),
      (.restricted, .restricted),
      (.notDetermined, .notDetermined),
      (.unknown, .unavailable),
    ]
    for (state, status) in expected {
      XCTAssertEqual(
        PermissionMapping.mapPhotoStatus(state),
        status,
        "\(state) must map to \(status)"
      )
    }
  }

  func testPhotoRequestResultCoversEveryAuthorizationState() {
    let expected: [(PhotoAuthorizationState, PermissionRequestResult)] = [
      (.authorized, .granted),
      (.limited, .limited),
      (.denied, .denied),
      // PermissionRequestResult has no .restricted case; parental-control
      // restriction therefore surfaces as .denied after a request attempt.
      (.restricted, .denied),
      // A photo authorization request should not complete as .notDetermined;
      // if it ever does, report .denied rather than claiming success.
      (.notDetermined, .denied),
      (.unknown, .unavailable),
    ]
    for (state, result) in expected {
      XCTAssertEqual(
        PermissionMapping.mapPhotoRequestResult(state),
        result,
        "\(state) must map to \(result)"
      )
    }
  }

  func testPhotoRequestResultOnlyGrantsForAuthorized() {
    // Safety property: no photo state other than .authorized may ever produce
    // a .granted request result.
    let nonAuthorizedStates: [PhotoAuthorizationState] = [
      .limited, .denied, .restricted, .notDetermined, .unknown,
    ]
    for state in nonAuthorizedStates {
      XCTAssertNotEqual(
        PermissionMapping.mapPhotoRequestResult(state),
        .granted,
        "\(state) must never yield a .granted request result"
      )
    }
  }

  // MARK: - Notifications

  func testNotificationStatusCoversEveryAuthorizationState() {
    let expected: [(NotificationAuthorizationState, PermissionStatus)] = [
      (.authorized, .authorized),
      // Provisional (quiet) and ephemeral (app clip) notifications are both
      // delivered in a restricted mode, so both surface as .limited.
      (.provisional, .limited),
      (.ephemeral, .limited),
      (.denied, .denied),
      (.notDetermined, .notDetermined),
      (.unknown, .unavailable),
    ]
    for (state, status) in expected {
      XCTAssertEqual(
        PermissionMapping.mapNotificationStatus(state),
        status,
        "\(state) must map to \(status)"
      )
    }
  }

  func testNotificationRequestResultMirrorsGrant() {
    XCTAssertEqual(PermissionMapping.mapNotificationRequestResult(granted: true), .granted)
    XCTAssertEqual(PermissionMapping.mapNotificationRequestResult(granted: false), .denied)
  }

  // MARK: - canProceed (UI gate)

  func testCanProceedIsTrueOnlyForGrantedAndLimited() {
    let expected: [(PermissionRequestResult, Bool)] = [
      (.granted, true),
      (.limited, true),
      (.denied, false),
      (.unavailable, false),
    ]
    for (result, proceed) in expected {
      XCTAssertEqual(
        PermissionMapping.canProceed(result),
        proceed,
        "canProceed(\(result)) must be \(proceed)"
      )
    }
  }

  func testCanProceedBlocksEveryPhotoRequestFailurePath() {
    // The gate composed with the photo request mapping: every photo state
    // that is not an explicit success (authorized/limited) must block the
    // UI from proceeding after a request.
    let expected: [(PhotoAuthorizationState, Bool)] = [
      (.authorized, true),
      (.limited, true),
      (.denied, false),
      (.restricted, false),
      (.notDetermined, false),
      (.unknown, false),
    ]
    for (state, proceed) in expected {
      XCTAssertEqual(
        PermissionMapping.canProceed(PermissionMapping.mapPhotoRequestResult(state)),
        proceed,
        "photo state \(state) must \(proceed ? "allow" : "block") proceeding after a request"
      )
    }
  }

  // MARK: - Unknown-state fallback contract

  func testUnknownAuthorizationStatesNeverGrantAccess() {
    // Across every mapping, `unknown` must fall back to a blocked outcome.
    // If a future OS adds an authorization case and the app routes it here as
    // .unknown, the worst case must be "unavailable", never "authorized".
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(cameraAvailable: true, authorizationState: .unknown),
      .unavailable
    )
    XCTAssertEqual(PermissionMapping.mapMicrophoneStatus(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapPhotoStatus(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapPhotoRequestResult(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapNotificationStatus(.unknown), .unavailable)
  }

  // MARK: - LiDAR

  func testLiDARAvailabilityMirrorsHardwareSupport() {
    XCTAssertEqual(PermissionMapping.mapLiDARAvailability(true), .available)
    XCTAssertEqual(PermissionMapping.mapLiDARAvailability(false), .unavailable)
  }
}
