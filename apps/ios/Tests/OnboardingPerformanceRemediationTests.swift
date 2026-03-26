import Foundation
import XCTest

final class OnboardingPerformanceRemediationTests: XCTestCase {
  func testOnboardingViewDefersAllergenCatalogLoadingOutOfInitialLoad() throws {
    let root = sourceRoot()

    let onboardingViewSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingView.swift"),
      encoding: .utf8
    )
    let loaderSource = try String(
      contentsOf: root.appendingPathComponent(
        "Feature/Onboarding/OnboardingAllergenCatalogLoader.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(onboardingViewSource.contains("await preloadAllergenCatalogIfNeeded()"))
    XCTAssertFalse(onboardingViewSource.contains("ingredientRepository.fetchAll()"))
    XCTAssertTrue(loaderSource.contains("ingredientRepository.fetchAll()"))
  }

  func testTransitionPolicyUsesSoftPairsForNameStepHandoffs() throws {
    let root = sourceRoot()

    let source = try String(
      contentsOf: root.appendingPathComponent(
        "Feature/Onboarding/OnboardingTransitionPolicy.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("(.welcome, .name)"))
    XCTAssertTrue(source.contains("(.name, .welcome)"))
    XCTAssertTrue(source.contains("(.name, .personalWelcome)"))
    XCTAssertTrue(source.contains("(.personalWelcome, .name)"))
    XCTAssertTrue(source.contains("case .softFade"))
  }

  func testOnboardingUsesInteractiveBackgroundModeAndDeferredFocus() throws {
    let root = sourceRoot()

    let onboardingViewSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingView.swift"),
      encoding: .utf8
    )
    let backgroundSource = try String(
      contentsOf: root.appendingPathComponent("DesignSystem/BackgroundSystem.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(
      onboardingViewSource.contains(
        ".flPageBackground(renderMode: currentStep.backgroundRenderMode)")
    )
    XCTAssertTrue(onboardingViewSource.contains("scheduleNameFocusIfNeeded(for: nextStep)"))
    XCTAssertTrue(backgroundSource.contains("case .interactive"))
    XCTAssertTrue(backgroundSource.contains("FLCachedGrainTexture"))
  }

  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
