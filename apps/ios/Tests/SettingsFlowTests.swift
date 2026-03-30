import Foundation
import XCTest

@testable import FridgeLuck

final class SettingsFlowTests: XCTestCase {
  func testSettingsRoutesCoverHubAndAllEditorDestinations() {
    XCTAssertEqual(
      SettingsRoute.allCases,
      [
        .overview,
        .profileBasics,
        .nutritionTargets,
        .foodPreferences,
        .integrations,
        .permissions,
        .appExperience,
        .dataAndPrivacy,
      ]
    )
  }

  @MainActor
  func testSettingsCoordinatorOpenAndPushManageNavigationPath() {
    let coordinator = SettingsCoordinator()

    coordinator.open(.profileBasics)
    XCTAssertEqual(coordinator.path, [.profileBasics])

    coordinator.push(.nutritionTargets)
    XCTAssertEqual(coordinator.path, [.profileBasics, .nutritionTargets])

    coordinator.open(.overview)
    XCTAssertEqual(coordinator.path, [])
  }

  @MainActor
  func testPreferencesStorePersistsValuesAndUsesInjectedDefaultsForHaptics() {
    let defaults = makeIsolatedDefaults()
    let store = AppPreferencesStore(defaults: defaults)

    store.appearance = .dark
    store.measurementUnit = .imperial
    store.defaultServings = 4
    store.hapticsEnabled = false

    let reloadedStore = AppPreferencesStore(defaults: defaults)
    XCTAssertEqual(reloadedStore.appearance, .dark)
    XCTAssertEqual(reloadedStore.measurementUnit, .imperial)
    XCTAssertEqual(reloadedStore.defaultServings, 4)
    XCTAssertFalse(reloadedStore.hapticsEnabled)
    XCTAssertFalse(AppPreferencesStore.isHapticsEnabled)

    reloadedStore.reset()
    XCTAssertEqual(reloadedStore.appearance, .system)
    XCTAssertEqual(reloadedStore.measurementUnit, .metric)
    XCTAssertEqual(reloadedStore.defaultServings, 1)
    XCTAssertTrue(reloadedStore.hapticsEnabled)
    XCTAssertTrue(AppPreferencesStore.isHapticsEnabled)
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "SettingsFlowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
