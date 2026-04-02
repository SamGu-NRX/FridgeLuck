import Foundation
import XCTest

final class SettingsTrackingRemindersViewTests: XCTestCase {
  func testSettingsHubLinksToTrackingRemindersRoute() throws {
    let hubSource = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Settings/SettingsHubView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(hubSource.contains("SettingsRoute.trackingReminders"))
    XCTAssertTrue(hubSource.contains("Tracking Reminders"))
  }

  func testTrackingRemindersViewIncludesPermissionActionAndTimePickerSheet() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent(
        "Feature/Settings/SettingsTrackingRemindersView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("Allow Notifications"))
    XCTAssertTrue(source.contains(".sheet(item: $editingKind)"))
    XCTAssertTrue(source.contains("DatePicker("))
    XCTAssertTrue(source.contains("Kitchen alerts"))
  }

  private func iosRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
