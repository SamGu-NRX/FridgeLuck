import FLFeatureLogic
import SwiftUI

/// A step's timer control. Before the timer starts it is the "Start 20-second timer" button;
/// once started the same spot shows the countdown, so the tap visibly did something and a second
/// tap has nothing to start (2026-10-16 walk: the button started a timer the guide never showed).
///
/// It observes the cook session itself because the guide holds the view model in plain `@State`,
/// which publishes nothing when a timer ticks.
struct CookingGuideStepTimer: View {
  @ObservedObject var cook: CookModeViewModel
  let step: Int
  let reduceMotion: Bool

  var body: some View {
    let seconds = cook.timerSeconds(forStep: step)
    let timer = cook.activeTimer(forStep: step)

    ZStack {
      if let timer {
        CookingGuideTimerCard(
          timer: timer,
          reduceMotion: reduceMotion,
          onCancel: { cook.removeTimer(id: timer.id) },
          onDismiss: { cook.acknowledgeTimer(id: timer.id) }
        )
        .transition(swapTransition)
      } else if let seconds, seconds > 0 {
        FLSecondaryButton(
          "Start \(CookingGuideStepPage.timerButtonLabel(seconds))",
          systemImage: "timer"
        ) {
          cook.startStepTimer(step: step)
        }
        .accessibilityIdentifier("guide_start_timer")
        .transition(swapTransition)
      }
    }
    // State indication: the button turns into the countdown in place. Starting a timer is an
    // occasional act, so it earns a short ease-out swap; Reduce Motion keeps only the fade.
    .animation(reduceMotion ? .easeOut(duration: 0.15) : AppMotion.standard, value: timer?.id)
  }

  private var swapTransition: AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
  }
}

/// The running, paused or finished timer, drawn like the guide's secondary buttons: cream
/// surface, oat hairline, serif numerals that echo the big step number.
struct CookingGuideTimerCard: View {
  let timer: CookTimerState
  let reduceMotion: Bool
  let onCancel: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: AppTheme.Space.md) {
      CookingGuideTimerRing(timer: timer, reduceMotion: reduceMotion)
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(timer.isFired ? "Time's up" : CookingGuideTimerFormat.clock(timer.remainingSeconds))
          .font(.system(size: 34, weight: .semibold, design: .serif))
          .monospacedDigit()
          .foregroundStyle(timer.isFired ? AppTheme.accent : AppTheme.textPrimary)
          .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
          .accessibilityIdentifier("guide_timer_remaining")

        Text(caption)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(timer.isFired ? "Done" : "Cancel") {
        timer.isFired ? onDismiss() : onCancel()
      }
      .font(.system(.headline, design: .serif, weight: .medium))
      .foregroundStyle(timer.isFired ? AppTheme.accent : AppTheme.textSecondary)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      .accessibilityIdentifier(timer.isFired ? "guide_timer_done" : "guide_timer_cancel")
      .accessibilityLabel(timer.isFired ? "Dismiss \(timer.label) timer" : "Cancel \(timer.label) timer")
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
    .background(
      timer.isFired ? AppTheme.accent.opacity(0.10) : AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(
          timer.isFired ? AppTheme.accent.opacity(0.45) : AppTheme.oat.opacity(0.45),
          lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("guide_timer_card")
  }

  private var caption: String {
    if timer.isFired { return "\(timer.label) timer finished" }
    if timer.isPaused { return "\(timer.label) timer paused" }
    return "\(timer.label) timer"
  }
}

/// The drain ring around the timer glyph. Constant motion, so it drains linearly between ticks;
/// with Reduce Motion it steps once a second instead of sliding.
struct CookingGuideTimerRing: View {
  let timer: CookTimerState
  let reduceMotion: Bool

  private var fraction: Double {
    guard !timer.isFired else { return 0 }
    guard let total = timer.totalSeconds, total > 0 else { return 1 }
    return min(max(Double(timer.remainingSeconds) / Double(total), 0), 1)
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(AppTheme.oat.opacity(0.35), lineWidth: 3)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(reduceMotion || timer.isPaused ? nil : .linear(duration: 1), value: fraction)
      Image(systemName: timer.isFired ? "bell.fill" : "timer")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(AppTheme.accent)
    }
    .accessibilityHidden(true)
  }
}

/// Timers from other steps, pinned above Back and Next so a timer keeps showing after the cook
/// moves on. The current step's own timer shows on the step instead.
struct CookingGuideOtherTimers: View {
  @ObservedObject var cook: CookModeViewModel
  /// The step on screen, or nil on the ingredients page.
  let currentStep: Int?
  let reduceMotion: Bool
  let contentHorizontalPadding: CGFloat

  private var timers: [CookTimerState] {
    let ownLabel = currentStep.map { CookModeViewModel.stepTimerLabel(step: $0) }
    return cook.state.timers.filter { !$0.isAcknowledged && $0.label != ownLabel }
  }

  var body: some View {
    let timers = timers
    VStack(spacing: AppTheme.Space.xs) {
      ForEach(timers, id: \.id) { timer in
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: timer.isFired ? "bell.fill" : "timer")
            .foregroundStyle(AppTheme.accent)
          Text(timer.label)
            .foregroundStyle(AppTheme.textSecondary)
          Text(timer.isFired ? "Time's up" : CookingGuideTimerFormat.clock(timer.remainingSeconds))
            .monospacedDigit()
            .foregroundStyle(timer.isFired ? AppTheme.accent : AppTheme.textPrimary)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
          Spacer(minLength: 0)
          Button(timer.isFired ? "Done" : "Cancel") {
            if timer.isFired {
              cook.acknowledgeTimer(id: timer.id)
            } else {
              cook.removeTimer(id: timer.id)
            }
          }
          .foregroundStyle(timer.isFired ? AppTheme.accent : AppTheme.textSecondary)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
          .accessibilityLabel(
            timer.isFired ? "Dismiss \(timer.label) timer" : "Cancel \(timer.label) timer")
        }
        .font(AppTheme.Typography.bodyMedium)
        .padding(.horizontal, AppTheme.Space.md)
        .background(
          timer.isFired ? AppTheme.accent.opacity(0.10) : AppTheme.surface,
          in: Capsule()
        )
        .overlay(Capsule().stroke(AppTheme.oat.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guide_other_timer")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .padding(.horizontal, contentHorizontalPadding)
    .padding(.bottom, timers.isEmpty ? 0 : AppTheme.Space.xs)
    .animation(reduceMotion ? .easeOut(duration: 0.15) : AppMotion.standard, value: timers.map(\.id))
  }
}

/// Feedback when any timer finishes while the guide is open: a haptic, and a VoiceOver
/// announcement naming the step. The scheduled notification only shows while the app is in the
/// background, and only if the user allowed notifications.
struct CookingGuideTimerAlerts: ViewModifier {
  @ObservedObject var cook: CookModeViewModel

  private var firedIDs: Set<String> {
    Set(cook.state.timers.filter { $0.isFired && !$0.isAcknowledged }.map(\.id))
  }

  func body(content: Content) -> some View {
    content
      .sensoryFeedback(.warning, trigger: firedIDs) { old, new in !new.subtracting(old).isEmpty }
      .onChange(of: firedIDs) { old, new in
        let labels = cook.state.timers.filter { new.subtracting(old).contains($0.id) }.map(\.label)
        guard !labels.isEmpty else { return }
        AccessibilityNotification.Announcement(
          "\(labels.joined(separator: " and ")) timer finished"
        ).post()
      }
  }
}

enum CookingGuideTimerFormat {
  /// "0:17", "12:05", "1:02:03".
  static func clock(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    let hours = s / 3600
    let minutes = (s % 3600) / 60
    let rest = s % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
    return String(format: "%d:%02d", minutes, rest)
  }
}
