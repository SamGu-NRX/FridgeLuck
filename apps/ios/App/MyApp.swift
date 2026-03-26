import SwiftUI
import UIKit

@main
struct FridgeLuckApp: App {
  @State private var dependencies: AppDependencies?
  @State private var loadError: Error?
  @State private var launchStarted = false
  @State private var splashGatePassed = false
  @State private var shouldShowFirstRunOnboarding = false
  @State private var firstRunExperienceStore = FirstRunExperienceStore()

  init() {
    #if DEBUG
      Self.resetTutorialStateForLaunch()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        if let loadError {
          ErrorView(error: loadError)
        } else if let dependencies, splashGatePassed {
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
          LaunchSplashView(
            isBootstrapping: dependencies == nil && loadError == nil
          )
        }
      }
      .environment(firstRunExperienceStore)
      .task {
        await bootstrapIfNeeded()
      }
    }
  }

  @MainActor
  private func bootstrapIfNeeded() async {
    guard !launchStarted else { return }
    launchStarted = true

    async let splashGate: Void = Task.sleep(nanoseconds: 950_000_000)

    do {
      let appDB = try await AppDatabase.setup()
      let resolvedDependencies = await MainActor.run {
        AppDependencies(appDatabase: appDB)
      }
      let hasLegacyProfile =
        (try? resolvedDependencies.userDataRepository.hasCompletedOnboarding()) ?? false

      try? await splashGate

      #if !DEBUG
        if hasLegacyProfile {
          firstRunExperienceStore.markLegacyCompletionIfNeeded()
        }
      #endif

      dependencies = resolvedDependencies
      shouldShowFirstRunOnboarding = !firstRunExperienceStore.hasCompletedCurrentVersion
      splashGatePassed = true
    } catch {
      try? await splashGate
      loadError = error
      splashGatePassed = true
    }
  }

  /// Keeps guided tours replayable on every debug launch.
  private static func resetTutorialStateForLaunch() {
    let defaults = UserDefaults.standard
    for key in TutorialStorageKeys.all {
      defaults.removeObject(forKey: key)
    }
    defaults.removeObject(forKey: "firstRunExperienceCompletedVersion")
    defaults.removeObject(forKey: "firstRunExperienceAppleHealthChoice")
  }
}

// MARK: - Splash View

private struct LaunchSplashView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isBootstrapping: Bool

  @State private var hasAppeared = false
  @State private var showDetails = false
  @State private var breatheScale: CGFloat = 1.0

  var body: some View {
    ZStack {
      FLAmbientBackground()
        .ignoresSafeArea()

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
