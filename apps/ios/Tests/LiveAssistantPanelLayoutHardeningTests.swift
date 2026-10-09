import CoreGraphics
import FLFeatureLogic
import XCTest

/// Hardening tests for the live-assistant panel detent layout math
/// (`LiveAssistantPanelLayout` and `LiveAssistantPanelDetent`).
///
/// Sign convention, confirmed against the `LiveAssistantView` call sites
/// (a `DragGesture` feeds `value.translation.height` straight into these
/// functions): a *negative* translation means the user dragged up and the
/// panel must grow, because `clampedHeight` subtracts the translation from
/// the starting detent height.
///
/// Weighting contract pinned here: `resolvedDetent` blends the current
/// clamped height (weight 0.55) with the predicted-end clamped height
/// (weight 0.45), then picks the detent whose height is nearest to that
/// blend. `min(by:)` compares with a strict `<` and keeps the first minimal
/// element, so exact distance ties always resolve to the lower detent
/// (peek over step, step over full).
final class LiveAssistantPanelLayoutHardeningTests: XCTestCase {
  // MARK: - clampedHeight bounds

  func testClampedHeightStaysWithinPeekAndFullForExtremeTranslations() {
    for screenHeight: CGFloat in [568, 900, 1320] {
      let minHeight = LiveAssistantPanelDetent.peek.height(in: screenHeight)
      let maxHeight = LiveAssistantPanelDetent.full.height(in: screenHeight)
      for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
        for translation: CGFloat in [-10_000, 10_000] {
          let height = LiveAssistantPanelLayout.clampedHeight(
            for: detent,
            translation: translation,
            screenHeight: screenHeight
          )
          XCTAssertTrue(
            height >= minHeight && height <= maxHeight,
            "height \(height) escaped [peek, full] for \(detent) at translation \(translation), screenHeight \(screenHeight)"
          )
        }
      }
    }
  }

  func testClampedHeightSaturatesAtFullForExtremeUpwardDrag() {
    // A huge upward drag (negative translation) must pin the panel exactly
    // at the full detent height for every starting detent.
    for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
      XCTAssertEqual(
        LiveAssistantPanelLayout.clampedHeight(
          for: detent,
          translation: -10_000,
          screenHeight: 900
        ),
        LiveAssistantPanelDetent.full.height(in: 900)
      )
    }
  }

  func testClampedHeightSaturatesAtPeekForExtremeDownwardDrag() {
    // Mirror of the upward case: a huge downward drag pins the panel at peek.
    for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
      XCTAssertEqual(
        LiveAssistantPanelLayout.clampedHeight(
          for: detent,
          translation: 10_000,
          screenHeight: 900
        ),
        LiveAssistantPanelDetent.peek.height(in: 900)
      )
    }
  }

  func testClampedHeightMatchesDetentHeightWhenTranslationIsZero() {
    for screenHeight: CGFloat in [568, 667, 844, 900, 1320] {
      for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
        XCTAssertEqual(
          LiveAssistantPanelLayout.clampedHeight(
            for: detent,
            translation: 0,
            screenHeight: screenHeight
          ),
          detent.height(in: screenHeight)
        )
      }
    }
  }

  func testClampedHeightTracksUpwardDragOneToOne() {
    // Within the unclamped range the panel must follow the finger exactly:
    // dragging 150pt further up (translation -150) means exactly 150pt more
    // height, not a damped or rubber-banded response.
    let base = LiveAssistantPanelLayout.clampedHeight(
      for: .step,
      translation: 0,
      screenHeight: 900
    )
    let dragged = LiveAssistantPanelLayout.clampedHeight(
      for: .step,
      translation: -150,
      screenHeight: 900
    )
    XCTAssertEqual(dragged, base + 150)
  }

  func testClampedHeightIsMonotonicInScreenHeight() {
    // Growing the screen must never shrink the panel for a fixed detent and
    // gesture, including the clamped regimes at both ends of the sweep.
    let screenHeights: [CGFloat] = [50, 100, 200, 305, 568, 667, 740, 844, 900, 1000, 1320, 2000]
    for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
      for translation: CGFloat in [0, -200, 300] {
        let heights = screenHeights.map {
          LiveAssistantPanelLayout.clampedHeight(
            for: detent,
            translation: translation,
            screenHeight: $0
          )
        }
        for (smaller, larger) in zip(heights, heights.dropFirst()) {
          XCTAssertLessThanOrEqual(smaller, larger)
        }
      }
    }
  }

  // MARK: - resolvedDetent ordering

  func testResolvedDetentIsMonotonicInUpwardPredictedTranslation() {
    // The stronger the upward prediction, the further the resolution may
    // move — never backwards. Sweeps every starting detent through both
    // clamp saturation points.
    for start in [LiveAssistantPanelDetent.peek, .step, .full] {
      for translation: CGFloat in [0, -100] {
        var previousOrdinal = -1
        for predicted in stride(from: 1200 as CGFloat, through: -1200, by: -10) {
          let resolved = LiveAssistantPanelLayout.resolvedDetent(
            from: start,
            translation: translation,
            predictedEndTranslation: predicted,
            screenHeight: 900
          )
          XCTAssertGreaterThanOrEqual(ordinal(of: resolved), previousOrdinal)
          previousOrdinal = ordinal(of: resolved)
        }
      }
    }
  }

  func testResolvedDetentIsMonotonicInUpwardDragTranslation() {
    // Same monotonic contract for the actual drag position (prediction held
    // fixed): dragging further up can only keep or raise the resolved detent.
    for start in [LiveAssistantPanelDetent.peek, .step, .full] {
      for predicted: CGFloat in [0, -100, 200, -800] {
        var previousOrdinal = -1
        for translation in stride(from: 2000 as CGFloat, through: -2000, by: -10) {
          let resolved = LiveAssistantPanelLayout.resolvedDetent(
            from: start,
            translation: translation,
            predictedEndTranslation: predicted,
            screenHeight: 900
          )
          XCTAssertGreaterThanOrEqual(ordinal(of: resolved), previousOrdinal)
          previousOrdinal = ordinal(of: resolved)
        }
      }
    }
  }

  func testResolvedDetentReturnsStartingDetentForZeroGesture() {
    // A gesture that neither moved nor predicted anything must not jump
    // detents — the panel stays put.
    for screenHeight: CGFloat in [667, 900, 1320] {
      for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
        XCTAssertEqual(
          LiveAssistantPanelLayout.resolvedDetent(
            from: detent,
            translation: 0,
            predictedEndTranslation: 0,
            screenHeight: screenHeight
          ),
          detent
        )
      }
    }
  }

  // MARK: - resolvedDetent weighting (0.55 current / 0.45 predicted)

  func testPredictionAloneCannotPromotePanelPastStep() {
    // From peek with the finger not yet moved, even an infinite upward
    // prediction is damped by the 0.45 weight: the blend tops out at
    // 0.55 * 116 + 0.45 * 648 = 355.4, below the 495 step/full midpoint at
    // screenHeight 900 — so the panel promotes to step, never straight to
    // full on prediction alone.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .peek,
        translation: 0,
        predictedEndTranslation: -10_000,
        screenHeight: 900
      ),
      .step
    )
  }

  func testPredictionAloneCannotCollapsePanelPastStep() {
    // Mirror from full: a maximal downward prediction blends to
    // 0.55 * 648 + 0.45 * 116 = 408.6, above the 229 peek/step midpoint at
    // screenHeight 900 — step, never straight to peek on prediction alone.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .full,
        translation: 0,
        predictedEndTranslation: 10_000,
        screenHeight: 900
      ),
      .step
    )
  }

  func testCommittedUpwardDragFromPeekResolvesToFull() {
    // When the finger itself carries the panel into the top clamp, the
    // resolution must land on full, not settle one detent short.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .peek,
        translation: -10_000,
        predictedEndTranslation: -10_000,
        screenHeight: 900
      ),
      .full
    )
  }

  func testCommittedDownwardDragFromFullResolvesToPeek() {
    // Mirror: dragging the panel fully down collapses it to peek.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .full,
        translation: 10_000,
        predictedEndTranslation: 10_000,
        screenHeight: 900
      ),
      .peek
    )
  }

  // MARK: - distance tie-breaks

  func testExactPeekStepDistanceTieResolvesToLowerDetent() {
    // At screenHeight 1000 the detent heights are exactly 116 / 380 / 720.
    // Starting at step with translation 24 (height 356) and predicted 264
    // (height 116), the blend is exactly 0.55 * 356 + 0.45 * 116 = 248 —
    // the precise peek/step midpoint. `min(by:)` compares with a strict `<`
    // and keeps the first minimal element, so the tie must resolve DOWN to
    // peek rather than up to step.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .step,
        translation: 24,
        predictedEndTranslation: 264,
        screenHeight: 1000
      ),
      .peek
    )
  }

  func testExactStepFullDistanceTieResolvesToLowerDetent() {
    // Same rule at the step/full boundary: translation -332 (height 712) and
    // predicted 28 (height 352) blend to exactly 0.55 * 712 + 0.45 * 352 =
    // 550, the precise step/full midpoint — step must win the tie over full.
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .step,
        translation: -332,
        predictedEndTranslation: 28,
        screenHeight: 1000
      ),
      .step
    )
  }

  // MARK: - degenerate screen sizes

  func testDegenerateTinyScreenCollapsesClampToSingleStableHeight() {
    // Below screenHeight ~161.1 the peek height (116) exceeds the full
    // height (0.72 * h), so the clamp range collapses to a single point.
    // This is unreachable from the app (the panel lives in a full-screen
    // navigation push and every supported device is at least 568pt tall), so
    // this only pins that the layout stays deterministic in that regime: one
    // constant height equal to the collapsed full bound, identical for every
    // detent and translation — never negative and never
    // translation-dependent.
    let fullHeight = LiveAssistantPanelDetent.full.height(in: 100)
    for detent in [LiveAssistantPanelDetent.peek, .step, .full] {
      for translation: CGFloat in [-1000, 0, 1000] {
        XCTAssertEqual(
          LiveAssistantPanelLayout.clampedHeight(
            for: detent,
            translation: translation,
            screenHeight: 100
          ),
          fullHeight
        )
      }
    }
  }

  private func ordinal(of detent: LiveAssistantPanelDetent) -> Int {
    switch detent {
    case .peek: return 0
    case .step: return 1
    case .full: return 2
    }
  }
}
