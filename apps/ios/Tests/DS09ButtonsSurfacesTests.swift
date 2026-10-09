import SwiftUI
import XCTest

@testable import FridgeLuck

/// Behavioral tests for the FLButton/FLSurface design-system slice:
/// label-key logic, press-state math, tone/kind color mapping, and content wiring.
final class DS09ButtonsSurfacesTests: XCTestCase {
  private typealias CardTone = FLCard<Color>.Tone
  private typealias PillKind = FLStatusPill.Kind

  // MARK: - FLPrimaryButton label key

  func testLabelKeyDistinguishesNilImageFromLiteralNoneSentinel() {
    // Regression: the old string key used `systemImage ?? "none"`, so a nil image and the
    // literal "none" image name produced one key and the subtleBlend animation stayed dead.
    XCTAssertNotEqual(
      FLPrimaryButton.LabelKey(title: "Add", systemImage: nil),
      FLPrimaryButton.LabelKey(title: "Add", systemImage: "none")
    )
  }

  func testLabelKeyIsStableForIdenticalInputs() {
    XCTAssertEqual(
      FLPrimaryButton.LabelKey(title: "Cook", systemImage: "flame"),
      FLPrimaryButton.LabelKey(title: "Cook", systemImage: "flame")
    )
  }

  func testLabelKeyChangesWhenTitleChanges() {
    XCTAssertNotEqual(
      FLPrimaryButton.LabelKey(title: "Cook", systemImage: nil),
      FLPrimaryButton.LabelKey(title: "Save", systemImage: nil)
    )
  }

  func testLabelKeyChangesWhenImageChanges() {
    XCTAssertNotEqual(
      FLPrimaryButton.LabelKey(title: "Cook", systemImage: "flame"),
      FLPrimaryButton.LabelKey(title: "Cook", systemImage: "plus")
    )
  }

  func testLabelKeyDisambiguatesSeparatorInTitle() {
    // "A|B" + "C" must not collapse into the same key as "A" + "B|C".
    XCTAssertNotEqual(
      FLPrimaryButton.LabelKey(title: "A|B", systemImage: "C"),
      FLPrimaryButton.LabelKey(title: "A", systemImage: "B|C")
    )
  }

  func testLabelKeyHandlesEmptyTitleAndImage() {
    XCTAssertNotEqual(
      FLPrimaryButton.LabelKey(title: "", systemImage: nil),
      FLPrimaryButton.LabelKey(title: "", systemImage: "none")
    )
    XCTAssertEqual(
      FLPrimaryButton.LabelKey(title: "", systemImage: nil),
      FLPrimaryButton.LabelKey(title: "", systemImage: nil)
    )
  }

  // MARK: - Button defaults

  @MainActor
  func testPrimaryButtonDefaultsToEnabledWithoutImageOrAnimation() {
    let button = FLPrimaryButton("Cook") {}

    XCTAssertEqual(button.title, "Cook")
    XCTAssertNil(button.systemImage)
    XCTAssertTrue(button.isEnabled)
    XCTAssertEqual(labelAnimationName(button.labelAnimation), "none")
  }

  @MainActor
  func testPrimaryButtonStoresProvidedValuesAndAction() {
    var fired = false
    let button = FLPrimaryButton(
      "Add",
      systemImage: "plus",
      isEnabled: false,
      labelAnimation: .subtleBlend
    ) { fired = true }

    XCTAssertEqual(labelAnimationName(button.labelAnimation), "subtleBlend")
    XCTAssertFalse(button.isEnabled)
    button.action()
    XCTAssertTrue(fired)
  }

  @MainActor
  func testSecondaryButtonDefaultsToEnabledWithoutImage() {
    let button = FLSecondaryButton("Cancel") {}

    XCTAssertEqual(button.title, "Cancel")
    XCTAssertNil(button.systemImage)
    XCTAssertTrue(button.isEnabled)
  }

  // MARK: - ButtonStyle press-state math

  func testPressableStyleScalesDownOnlyWhilePressed() {
    let rest = FLPressableButtonStyle.scale(isPressed: false)
    let pressed = FLPressableButtonStyle.scale(isPressed: true)

    XCTAssertEqual(rest, 1)
    XCTAssertNotEqual(rest, pressed)
    XCTAssertLessThan(pressed, rest)
  }

  func testPressableStylePressedScaleStaysInSaneBand() {
    // Disabled-while-pressed safety: the style keys off isPressed alone and must
    // never invert or grow the label.
    let pressed = FLPressableButtonStyle.scale(isPressed: true)
    XCTAssertGreaterThanOrEqual(pressed, 0.9)
    XCTAssertLessThanOrEqual(pressed, 1.0)
  }

  func testHeroCardStyleScalesDownOnlyWhilePressed() {
    let rest = FLHeroCardButtonStyle.scale(isPressed: false)
    let pressed = FLHeroCardButtonStyle.scale(isPressed: true)

    XCTAssertEqual(rest, 1)
    XCTAssertNotEqual(rest, pressed)
    XCTAssertLessThan(pressed, rest)
    XCTAssertGreaterThanOrEqual(pressed, 0.9)
    XCTAssertLessThanOrEqual(pressed, 1.0)
  }

  func testAddChipStyleScaleAndOpacityDifferPerState() {
    let restScale = FLAddChipButtonStyle.scale(isPressed: false)
    let pressedScale = FLAddChipButtonStyle.scale(isPressed: true)
    let restOpacity = FLAddChipButtonStyle.opacity(isPressed: false)
    let pressedOpacity = FLAddChipButtonStyle.opacity(isPressed: true)

    XCTAssertEqual(restScale, 1)
    XCTAssertEqual(restOpacity, 1)
    XCTAssertLessThan(pressedScale, restScale)
    XCTAssertLessThan(pressedOpacity, restOpacity)
  }

  func testAddChipStylePressedValuesStayInSaneBand() {
    let pressedScale = FLAddChipButtonStyle.scale(isPressed: true)
    let pressedOpacity = FLAddChipButtonStyle.opacity(isPressed: true)
    XCTAssertGreaterThanOrEqual(pressedScale, 0.9)
    XCTAssertLessThanOrEqual(pressedScale, 1.0)
    XCTAssertGreaterThanOrEqual(pressedOpacity, 0.5)
    XCTAssertLessThanOrEqual(pressedOpacity, 1.0)
  }

  func testPressScalesAreDistinctPerStyle() {
    // Each style intentionally presses to its own depth; a copy-paste unification
    // should be caught here.
    XCTAssertNotEqual(
      FLPressableButtonStyle.scale(isPressed: true),
      FLHeroCardButtonStyle.scale(isPressed: true)
    )
    XCTAssertNotEqual(
      FLPressableButtonStyle.scale(isPressed: true),
      FLAddChipButtonStyle.scale(isPressed: true)
    )
    XCTAssertNotEqual(
      FLHeroCardButtonStyle.scale(isPressed: true),
      FLAddChipButtonStyle.scale(isPressed: true)
    )
  }

  // MARK: - FLCard tone mapping

  func testCardToneFillMatchesThemeContract() {
    XCTAssertEqual(CardTone.normal.fill, AppTheme.surfaceElevated)
    XCTAssertEqual(CardTone.warm.fill, AppTheme.surfaceMuted)
    XCTAssertEqual(CardTone.success.fill, AppTheme.sage.opacity(0.08))
    XCTAssertEqual(CardTone.warning.fill, AppTheme.accent.opacity(0.07))
  }

  func testCardToneFillsAreDistinctPerTone() {
    let fills = [
      CardTone.normal.fill,
      CardTone.warm.fill,
      CardTone.success.fill,
      CardTone.warning.fill,
    ]
    XCTAssertEqual(Set(fills).count, fills.count)
  }

  func testCardToneStrokeMatchesThemeContract() {
    XCTAssertEqual(CardTone.normal.stroke, AppTheme.oat.opacity(0.30))
    XCTAssertEqual(CardTone.warm.stroke, AppTheme.oat.opacity(0.40))
    XCTAssertEqual(CardTone.success.stroke, AppTheme.sage.opacity(0.30))
    XCTAssertEqual(CardTone.warning.stroke, AppTheme.accent.opacity(0.28))
  }

  func testCardToneStrokesAreDistinctPerTone() {
    let strokes = [
      CardTone.normal.stroke,
      CardTone.warm.stroke,
      CardTone.success.stroke,
      CardTone.warning.stroke,
    ]
    XCTAssertEqual(Set(strokes).count, strokes.count)
  }

  // MARK: - FLStatusPill kind mapping

  func testStatusPillKindColorsMatchThemeAliases() {
    XCTAssertEqual(PillKind.positive.color, AppTheme.positive)
    XCTAssertEqual(PillKind.warning.color, AppTheme.warning)
    XCTAssertEqual(PillKind.neutral.color, AppTheme.neutral)
  }

  func testStatusPillKindColorsAreDistinct() {
    let colors = [
      PillKind.positive.color,
      PillKind.warning.color,
      PillKind.neutral.color,
    ]
    XCTAssertEqual(Set(colors).count, colors.count)
  }

  // MARK: - FLSectionHeader

  @MainActor
  func testSectionHeaderSubtitleDefaultsToNil() {
    let header = FLSectionHeader("Pantry", icon: "refrigerator")

    XCTAssertEqual(header.title, "Pantry")
    XCTAssertNil(header.subtitle)
    XCTAssertEqual(header.icon, "refrigerator")
  }

  @MainActor
  func testSectionHeaderStoresEmptySubtitleVerbatim() {
    // Hiding empty subtitles is body logic; storage must round-trip the input as given.
    let header = FLSectionHeader("Pantry", subtitle: "", icon: "refrigerator")

    XCTAssertEqual(header.subtitle, "")
  }

  // MARK: - FLEmptyState

  @MainActor
  func testEmptyStateOptionalActionDefaultsToNil() {
    let view = FLEmptyState(
      title: "No meals yet",
      message: "Scan a fridge to get started",
      systemImage: "fork.knife"
    )

    XCTAssertNil(view.actionTitle)
    XCTAssertNil(view.action)
  }

  @MainActor
  func testEmptyStateStoresActionPairWhenBothProvided() {
    var fired = false
    let view = FLEmptyState(
      title: "No meals yet",
      message: "Scan a fridge to get started",
      systemImage: "fork.knife",
      actionTitle: "Scan",
      action: { fired = true }
    )

    XCTAssertEqual(view.actionTitle, "Scan")
    view.action?()
    XCTAssertTrue(fired)
  }

  // MARK: - FLActionBar

  @MainActor
  func testActionBarEvaluatesContentBuilderExactlyOnce() {
    CountingContent.buildCount = 0

    let bar = FLActionBar { CountingContent() }
    _ = bar.body

    XCTAssertEqual(CountingContent.buildCount, 1)
  }

  // MARK: - Helpers

  private func labelAnimationName(_ animation: FLPrimaryButton.LabelAnimation) -> String {
    switch animation {
    case .none: return "none"
    case .subtleBlend: return "subtleBlend"
    }
  }

  private struct CountingContent: View {
    nonisolated(unsafe) static var buildCount = 0
    init() { Self.buildCount += 1 }
    var body: some View { Color.clear }
  }
}
