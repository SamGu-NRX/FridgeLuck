import SwiftUI
import UIKit

@main
struct FridgeLuckApp: App {
  @State private var dependencies: AppDependencies?
  @State private var loadError: Error?
  @State private var launchStarted = false
  @State private var shouldShowFirstRunOnboarding = false
  @State private var firstRunExperienceStore = FirstRunExperienceStore()
  @State private var preferencesStore = AppPreferencesStore()

  init() {
    #if DEBUG
      if Self.shouldResetTutorialStateForLaunch {
        Self.resetTutorialStateForLaunch()
      }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        if let loadError {
          ErrorView(error: loadError)
        } else if let dependencies {
          if shouldShowFirstRunOnboarding {
            OnboardingView(isRequired: true) {
              firstRunExperienceStore.markCompletedCurrentVersion()
              shouldShowFirstRunOnboarding = false
            }
            .environmentObject(dependencies)
          } else {
            ContentView()
              .environmentObject(dependencies)
          }
        } else {
          LaunchSplashView()
        }
      }
      .environment(firstRunExperienceStore)
      .environment(preferencesStore)
      .preferredColorScheme(preferencesStore.appearance.colorScheme)
      .task {
        await bootstrapIfNeeded()
      }
    }
  }

  @MainActor
  private func bootstrapIfNeeded() async {
    guard !launchStarted else { return }
    launchStarted = true

    do {
      let appDB = try await Task.detached(priority: .userInitiated) {
        try await AppDatabase.setup()
      }.value
      let resolvedDependencies = await MainActor.run {
        AppDependencies(appDatabase: appDB)
      }
      let hasLegacyProfile =
        (try? resolvedDependencies.userDataRepository.hasCompletedOnboarding()) ?? false

      #if !DEBUG
        if hasLegacyProfile {
          firstRunExperienceStore.markLegacyCompletionIfNeeded()
        }
      #endif

      dependencies = resolvedDependencies
      shouldShowFirstRunOnboarding = !firstRunExperienceStore.hasCompletedCurrentVersion
      warmBundledContentInBackground(using: appDB)
    } catch {
      loadError = error
    }
  }

  private static func resetTutorialStateForLaunch() {
    let defaults = UserDefaults.standard
    for key in TutorialStorageKeys.all {
      defaults.removeObject(forKey: key)
    }
    defaults.removeObject(forKey: "firstRunExperienceCompletedVersion")
    defaults.removeObject(forKey: "firstRunExperienceAppleHealthChoice")
    for key in [
      "appPref_appearance", "appPref_measurementUnit", "appPref_defaultServings",
      "appPref_hapticsEnabled",
    ] {
      defaults.removeObject(forKey: key)
    }
  }

  private static var shouldResetTutorialStateForLaunch: Bool {
    ProcessInfo.processInfo.environment["FL_RESET_TUTORIAL_STATE_ON_LAUNCH"] == "1"
  }

  private func warmBundledContentInBackground(using appDatabase: AppDatabase) {
    Task.detached(priority: .utility) {
      try? await appDatabase.warmBundledContentIfNeeded()
    }
  }
}

// MARK: - Splash View

private struct LaunchSplashView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var hasAppeared = false
  @State private var showDetails = false
  @State private var breatheScale: CGFloat = 1.0

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [AppTheme.bg, AppTheme.bgDeep.opacity(0.72)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      Circle()
        .fill(
          RadialGradient(
            colors: [AppTheme.accent.opacity(0.14), Color.clear],
            center: .center,
            startRadius: 12,
            endRadius: 150
          )
        )
        .frame(width: 260, height: 260)
        .offset(x: 120, y: -260)
        .blur(radius: 26)

      Circle()
        .fill(
          RadialGradient(
            colors: [AppTheme.sage.opacity(0.12), Color.clear],
            center: .center,
            startRadius: 10,
            endRadius: 140
          )
        )
        .frame(width: 240, height: 240)
        .offset(x: -100, y: 240)
        .blur(radius: 30)

      VStack(spacing: AppTheme.Space.lg) {
        ZStack {
          // Breathing glow behind logo
          Circle()
            .fill(
              RadialGradient(
                colors: [
                  AppTheme.accentLight.opacity(0.35),
                  AppTheme.oat.opacity(0.15),
                  Color.clear,
                ],
                center: .center,
                startRadius: 20,
                endRadius: 120
              )
            )
            .frame(width: 240, height: 240)
            .blur(radius: 30)
            .scaleEffect(breatheScale)
            .opacity(hasAppeared ? 0.9 : 0)

          splashMark
        }
        .scaleEffect(hasAppeared ? 1 : 0.94)
        .opacity(hasAppeared ? 1 : 0)

        VStack(spacing: AppTheme.Space.xxs) {
          Text("FridgeLuck")
            .font(AppTheme.Typography.displayLarge)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Cook with what you have.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .opacity(showDetails ? 1 : 0)
        .offset(y: showDetails ? 0 : 8)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .onAppear {
      guard !hasAppeared else { return }
      if reduceMotion {
        hasAppeared = true
        showDetails = true
      } else {
        withAnimation(.timingCurve(0.19, 1.0, 0.22, 1.0, duration: 0.42)) {
          hasAppeared = true
        }
        withAnimation(.easeOut(duration: 0.22).delay(0.16)) {
          showDetails = true
        }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
          breatheScale = 1.08
        }
      }
    }
  }

  private var splashMark: some View {
    Group {
      if UIImage(named: "FridgeLuckLogo") != nil {
        Image("FridgeLuckLogo")
          .resizable()
          .scaledToFill()
          .frame(width: 120, height: 120)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous))
          .shadow(color: AppTheme.Shadow.colorDeep, radius: 20, x: 0, y: 10)
      } else {
        Image(systemName: "refrigerator.fill")
          .font(.system(size: 64, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
      }
    }
  }
}

// MARK: - Error View

private struct ErrorView: View {
  let error: Error

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.yellow)
      Text("Something went wrong")
        .font(.title2.bold())
      Text(error.localizedDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
  }
}
