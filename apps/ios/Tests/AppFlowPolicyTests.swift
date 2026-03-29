import FLFeatureLogic
import XCTest

final class AppFlowPolicyTests: XCTestCase {
  func testScanEntryRouteRequiresOnboardingWhenProfileMissing() {
    XCTAssertEqual(AppFlowPolicy.scanEntryRoute(hasOnboarded: false), .onboarding)
  }

  func testScanEntryRouteGoesToScanWhenOnboarded() {
    XCTAssertEqual(AppFlowPolicy.scanEntryRoute(hasOnboarded: true), .scan)
  }

  func testSettingsEntryRouteAlwaysUsesSettingsSurface() {
    XCTAssertEqual(
      AppFlowPolicy.settingsEntryRoute(),
      .settings
    )
  }

  func testResetPolicyKeepsProgressKeyWhileClearingOtherTutorialKeys() {
    let keys = ResetPolicy.tutorialKeysToClear(
      allKeys: ["progress", "spotlight_shown", "scan_hint"],
      preserving: "progress"
    )
    XCTAssertEqual(keys, ["spotlight_shown", "scan_hint"])
  }

  func testResetPolicyCombinesLearningAndTutorialKeys() {
    let keys = ResetPolicy.defaultsKeysToClear(
      tutorialKeys: ["t1", "t2"],
      learningKeys: ["l1", "l2"]
    )
    XCTAssertEqual(keys, ["l1", "l2", "t1", "t2"])
  }
}
