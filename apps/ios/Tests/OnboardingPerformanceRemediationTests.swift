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

  func testOnboardingKeepsEarlyStepsOnLiveBackground() throws {
    let root = sourceRoot()

    let stepSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingStep.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(stepSource.contains("case .name,"))
    XCTAssertFalse(stepSource.contains("case .personalWelcome,"))
    XCTAssertTrue(stepSource.contains("case .age,"))
  }

  func testOnboardingDefersNameFocusUntilAfterSettle() throws {
    let root = sourceRoot()

    let onboardingViewSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingView.swift"),
      encoding: .utf8
    )
    let sectionsSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingViewSections.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(onboardingViewSource.contains("scheduleNameFocusIfNeeded(for: nextStep)"))
    XCTAssertTrue(
      onboardingViewSource.contains("static let nameFocusSettleNanoseconds: UInt64 = 180_000_000")
    )
    XCTAssertTrue(
      onboardingViewSource.contains(
        "static let reducedMotionNameFocusSettleNanoseconds: UInt64 = 90_000_000")
    )
    XCTAssertTrue(onboardingViewSource.contains("await Task.yield()"))
    XCTAssertTrue(
      sectionsSource.contains(
        """
        TextField("Your name", text: $displayName)
                  .font(.system(size: 24, weight: .medium, design: .serif))
                  .multilineTextAlignment(.center)
                  .textInputAutocapitalization(.words)
                  .autocorrectionDisabled(true)
                  .focused($isNameFocused)
        """
      )
    )
  }

  func testBackgroundRendererUsesStableSizingAndBackgroundQueue() throws {
    let root = sourceRoot()

    let backgroundSource = try String(
      contentsOf: root.appendingPathComponent("DesignSystem/BackgroundSystem.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(backgroundSource.contains("@State private var stableSize: CGSize = .zero"))
    XCTAssertTrue(backgroundSource.contains("height: max(stableSize.height, size.height)"))
    XCTAssertTrue(backgroundSource.contains("label: \"samgu.FridgeLuck.cachedGrainTexture\""))
    XCTAssertTrue(backgroundSource.contains(".task(id: cacheKey(for: geo.size))"))
    XCTAssertTrue(
      backgroundSource.contains(
        "@MainActor\n  private func requestGrainImage(for size: CGSize) async"))
  }

  func testOnboardingCompletionBridgesIntoHomeBeforeSpotlight() throws {
    let root = sourceRoot()

    let contentSource = try String(
      contentsOf: root.appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )
    let homeSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Home/HomeDashboardView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(contentSource.contains("OnboardingHomeHandoffOverlay"))
    XCTAssertTrue(contentSource.contains("beginOnboardingHandoff()"))
    XCTAssertTrue(contentSource.contains("releaseOnboardingHandoff()"))
    XCTAssertTrue(homeSource.contains("prefersAcceleratedOnboardingSpotlight"))
    XCTAssertTrue(homeSource.contains("onOnboardingSpotlightWillPresent()"))
    XCTAssertTrue(homeSource.contains("handleSpotlightDismissal(for: presentation.source)"))
  }

  func testKitchenReviewDoesNotReserveHiddenFooterSpace() throws {
    let root = sourceRoot()

    let onboardingViewSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingView.swift"),
      encoding: .utf8
    )
    let inventoryStepsSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingInventorySteps.swift"),
      encoding: .utf8
    )
    let sectionsSource = try String(
      contentsOf: root.appendingPathComponent("Feature/Onboarding/OnboardingViewSections.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(onboardingViewSource.contains("if currentStep.showsFooterActions"))
    XCTAssertFalse(onboardingViewSource.contains("EmptyView()"))
    XCTAssertFalse(onboardingViewSource.contains("OnboardingFooter.reservedHeight"))
    XCTAssertTrue(inventoryStepsSource.contains(".frame(height: AppTheme.Space.lg)"))
    XCTAssertFalse(sectionsSource.contains("static let reservedHeight"))
  }

  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
