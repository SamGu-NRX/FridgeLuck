import Foundation
import XCTest

final class SettingsFlowTests: XCTestCase {
  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testSettingsRoutesCoverHubAndAllEditorDestinations() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent("Feature/Settings/SettingsRoute.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("case overview"))
    XCTAssertTrue(source.contains("case profileBasics"))
    XCTAssertTrue(source.contains("case nutritionTargets"))
    XCTAssertTrue(source.contains("case foodPreferences"))
    XCTAssertTrue(source.contains("case integrations"))
    XCTAssertTrue(source.contains("case permissions"))
    XCTAssertTrue(source.contains("case appExperience"))
    XCTAssertTrue(source.contains("case dataAndPrivacy"))
  }

  func testSettingsViewUsesNavigationStackAndReplayOnboarding() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent("Feature/Settings/SettingsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("NavigationStack(path: $coordinator.path)"))
    XCTAssertTrue(source.contains(".navigationDestination(for: SettingsRoute.self)"))
    XCTAssertTrue(source.contains("showReplayOnboarding = true"))
    XCTAssertTrue(source.contains("OnboardingView(isRequired: false)"))
    XCTAssertTrue(source.contains("applyAppleHealthAuthorizationRequest"))
  }

  func testSettingsEditorsPersistThroughUserDataRepository() throws {
    let root = sourceRoot()
    let profileSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Settings/SettingsProfileBasicsView.swift"),
      encoding: .utf8
    )
    let nutritionSource = try String(
      contentsOf: root.appendingPathComponent(
        "Feature/Settings/SettingsNutritionTargetsView.swift"),
      encoding: .utf8
    )
    let foodSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Settings/SettingsFoodPreferencesView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(profileSource.contains("try deps.userDataRepository.saveHealthProfile(profile)"))
    XCTAssertTrue(
      nutritionSource.contains("try deps.userDataRepository.saveHealthProfile(profile)"))
    XCTAssertTrue(foodSource.contains("try deps.userDataRepository.saveHealthProfile(profile)"))
    XCTAssertFalse(profileSource.contains("OnboardingView(isRequired: false)"))
    XCTAssertFalse(nutritionSource.contains("OnboardingView(isRequired: false)"))
    XCTAssertFalse(foodSource.contains("OnboardingView(isRequired: false)"))
  }

  func testDataAndPrivacyHandsResetBackToAppShell() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Settings/SettingsDataAndPrivacyView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("let onResetAllData: () -> Void"))
    XCTAssertTrue(source.contains("onResetAllData()"))
    XCTAssertTrue(source.contains("AppPermissionCenter.openAppSettings()"))
  }
}
