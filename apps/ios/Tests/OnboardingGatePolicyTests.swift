import Foundation
import XCTest

final class OnboardingGatePolicyTests: XCTestCase {
  func testRepositoryRequiresNameAndAgeForOnboardingCompletion() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let source = try String(
      contentsOf: root.appendingPathComponent(
        "Platform/Persistence/Repository/UserDataRepository.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("onboardingAgeRange = 13...100"))
    XCTAssertTrue(source.contains("profile.normalizedDisplayName"))
    XCTAssertTrue(source.contains("guard let age = profile.age else { return false }"))
    XCTAssertTrue(source.contains("Self.onboardingAgeRange.contains(age)"))
  }

  func testContentViewUsesRealSettingsTabAndRemovesLegacyProfileSheets() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("case settings"))
    XCTAssertTrue(source.contains("SettingsView("))
    XCTAssertTrue(source.contains("settingsCoordinator.open(.profileBasics)"))
    XCTAssertTrue(
      source.contains(
        "navItem(icon: \"gearshape\", label: \"Settings\", isActive: selectedTab == .settings)"
      ))
    XCTAssertFalse(source.contains("showSettings"))
    XCTAssertFalse(source.contains("showProfile"))
    XCTAssertFalse(source.contains(".sheet(isPresented: $showSettings)"))
    XCTAssertFalse(source.contains(".sheet(isPresented: $showProfile)"))
  }
}
