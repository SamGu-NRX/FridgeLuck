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

  var body: some View {
    ZStack {
      FLAmbientBackground()
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.xl) {
        ZStack {
          Circle()
            .fill(
              LinearGradient(
                colors: [AppTheme.heroLight.opacity(0.85), AppTheme.accentLight.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 184, height: 184)
            .blur(radius: 14)

          RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
            .fill(AppTheme.surface.opacity(0.88))
            .background(
              .ultraThinMaterial,
              in: RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
            )
            .frame(width: 160, height: 160)
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.xxl, style: .continuous)
                .stroke(AppTheme.oat.opacity(0.28), lineWidth: 1)
            )

          if UIImage(named: "FridgeLuckLogo") != nil {
            Image("FridgeLuckLogo")
              .resizable()
              .scaledToFit()
              .frame(width: 96, height: 96)
          } else {
            Image(systemName: "refrigerator.fill")
              .font(.system(size: 56, weight: .semibold))
              .foregroundStyle(AppTheme.accent)
          }
        }
        .scaleEffect(hasAppeared ? 1 : 0.94)
        .opacity(hasAppeared ? 1 : 0)

        VStack(spacing: AppTheme.Space.xs) {
          Text("FridgeLuck")
            .font(AppTheme.Typography.displayLarge)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Turn what you have into meals you can trust.")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)

        HStack(spacing: AppTheme.Space.sm) {
          ProgressView()
            .controlSize(.small)
            .tint(AppTheme.accent)

          Text(isBootstrapping ? "Setting up your kitchen..." : "Opening FridgeLuck...")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .opacity(hasAppeared ? 1 : 0)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .onAppear {
      guard !hasAppeared else { return }
      if reduceMotion {
        hasAppeared = true
      } else {
        withAnimation(.timingCurve(0.19, 1.0, 0.22, 1.0, duration: 0.42)) {
          hasAppeared = true
        }
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
