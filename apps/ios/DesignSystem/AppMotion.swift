import SwiftUI

enum AppMotion {
  static let standard: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)
  static let gentle: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.20)
  static let quick: Animation = .timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.14)
  static let press: Animation = .timingCurve(0.18, 0.9, 0.22, 1.0, duration: 0.12)
  static let onboardingStep: Animation = .timingCurve(0.18, 0.96, 0.24, 1.0, duration: 0.22)
  static let onboardingHandoffIn: Animation = .timingCurve(
    0.18, 1.0, 0.32, 1.0, duration: 0.30)
  static let onboardingHandoffOut: Animation = .timingCurve(
    0.4, 0.0, 0.2, 1.0, duration: 0.28)
  static let spotlightEntry: Animation = .timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.22)
  static let spotlightDimmer: Animation = .timingCurve(0.18, 1.0, 0.32, 1.0, duration: 0.20)
  static let spotlightCardEntry: Animation = .spring(response: 0.40, dampingFraction: 0.84)
  static let spotlightDismiss: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.20)
  static let spotlightMove: Animation = .spring(response: 0.30, dampingFraction: 0.88)
  static let staggerDelay: Double = 0.035

  static let cardSpring: Animation = .spring(response: 0.35, dampingFraction: 0.72)
  static let buttonSpring: Animation = .spring(response: 0.28, dampingFraction: 0.68)
  static let heroAppear: Animation = .spring(response: 0.5, dampingFraction: 0.78)
  static let chartReveal: Animation = .spring(response: 0.6, dampingFraction: 0.82)

  static let pageTurn: Animation = .spring(response: 0.38, dampingFraction: 0.80)
  static let celebration: Animation = .spring(response: 0.55, dampingFraction: 0.70)
  static let starBounce: Animation = .spring(response: 0.24, dampingFraction: 0.55)
  static let counterReveal: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.6)
  static let sectionReveal: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
  static let confettiDuration: Double = 2.8

  // Scan-mode fan menu — independent X/Y springs
  static let menuExpandX: Animation = .spring(response: 0.32, dampingFraction: 0.84)
  static let menuSettleY: Animation = .spring(response: 0.48, dampingFraction: 0.72)
  static let menuPresence: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.12)
  static let menuScale: Animation = .spring(response: 0.35, dampingFraction: 0.80)
  static let menuLabel: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.14)
  static let menuDismiss: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.18)

  // Onboarding — step-by-step flow
  static let rulerDrag: Animation = .spring(response: 0.18, dampingFraction: 0.92)
  static let rulerSnap: Animation = .spring(response: 0.20, dampingFraction: 0.90)
  static let selectionPress: Animation = .spring(response: 0.24, dampingFraction: 0.80)
  static let chipToggle: Animation = .spring(response: 0.22, dampingFraction: 0.76)
  static let chipReflow: Animation = .timingCurve(0.645, 0.045, 0.355, 1.0, duration: 0.22)
  static let progressBar: Animation = .spring(response: 0.40, dampingFraction: 0.84)

  // Color transitions — selection states, toggles, status changes
  static let colorTransition: Animation = .timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.15)
  static let settingsDisclosureExpand: Animation = .timingCurve(
    0.22, 1.0, 0.36, 1.0, duration: 0.24
  )
  static let settingsDisclosureCollapse: Animation = .timingCurve(
    0.18, 1.0, 0.30, 1.0, duration: 0.18
  )

  // Onboarding — staggered entrance system
  static let staggerEntrance: Animation = .spring(response: 0.45, dampingFraction: 0.82)
  static let staggerInterval: Double = 0.06
  static let ringFill: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.2)
  static let heroEntrance: Animation = .spring(response: 0.55, dampingFraction: 0.80)
  static let heroPill: Animation = .spring(response: 0.50, dampingFraction: 0.75)
  static let bridgeAutoDuration: Double = 2.8
  static let confettiBurst: Animation = .spring(response: 0.60, dampingFraction: 0.65)
  static let messageCrossfade: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.35)

  // Camera Capture — still-photo viewfinder
  static let viewfinderBreathing: Animation = .easeInOut(duration: 2.5)
  static let shutterFlash: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.15)
  static let thumbnailLand: Animation = .spring(response: 0.30, dampingFraction: 0.72)
  static let cameraReveal: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.30)

  // Live Assistant — camera-first cooking guide
  static let panelSnap: Animation = .spring(response: 0.38, dampingFraction: 0.82)
  static let bubbleAppear: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
  static let bubbleDismiss: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.30)
  static let micPulse: Animation = .easeInOut(duration: 1.2)
  static let cameraResize: Animation = .spring(response: 0.40, dampingFraction: 0.84)

  // MARK: - Progress / shell

  static let ringFillProgress: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.0)
  static let streakCelebration: Animation = .spring(response: 0.45, dampingFraction: 0.65)
  static let tabEntrance: Animation = .spring(response: 0.38, dampingFraction: 0.82)
  static let shimmer: Animation = .easeInOut(duration: 1.5)
}
