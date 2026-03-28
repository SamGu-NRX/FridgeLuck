import Foundation
import XCTest

final class LaunchPerformanceRemediationTests: XCTestCase {
  func testAppBootstrapDoesNotUseArtificialSplashDelay() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/MyApp.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("950_000_000"))
    XCTAssertFalse(source.contains("splashGatePassed"))
  }

  func testAppBootstrapWarmsBundledContentAfterDependenciesResolve() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/MyApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("Task.detached(priority: .userInitiated)"))
    XCTAssertTrue(source.contains("warmBundledContentInBackground(using: appDB)"))
    XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
  }

  func testDebugTutorialResetIsOptIn() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/MyApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("FL_RESET_TUTORIAL_STATE_ON_LAUNCH"))
    XCTAssertTrue(source.contains("if Self.shouldResetTutorialStateForLaunch"))
  }

  func testAppDatabaseSetupDefersBundledHydration() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent("Platform/Persistence/Database/AppDatabase.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("func warmBundledContentIfNeeded() async throws"))
    XCTAssertTrue(
      source.contains("try await BundledDataLoader.ensureBundledRecipesHydrated(into: self)"))
    XCTAssertTrue(
      source.contains("try await BundledDataLoader.ensureUSDACatalogHydrated(into: self)"))
  }

  func testLaunchSplashAvoidsAmbientBackgroundRenderer() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent("App/MyApp.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("FLAmbientBackground()"))
    XCTAssertTrue(source.contains("LinearGradient("))
  }

  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
