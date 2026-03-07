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

  func testContentViewUsesSingleRouteSourceForDashboardNavLabelAndAction() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("private var dashboardNavRoute: DashboardEntryRoute"))
    XCTAssertTrue(source.contains("switch dashboardNavRoute"))
    XCTAssertTrue(source.contains("return \"Onboarding\""))
    XCTAssertTrue(source.contains("return \"Profile\""))
    XCTAssertTrue(source.contains("return \"Dashboard\""))
    XCTAssertTrue(source.contains("openDashboardTab()"))
  }
}
