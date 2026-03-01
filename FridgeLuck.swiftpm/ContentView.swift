import SwiftUI

// MARK: - Navigation Coordinator

/// Lightweight coordinator that allows deeply nested views (e.g. cooking celebration)
/// to signal the root ContentView to collapse the entire NavigationStack back to Home.
@Observable
final class NavigationCoordinator {
  var shouldReturnHome = false
  var didCompleteCooking = false

  func returnHome() {
    shouldReturnHome = true
  }

  /// Signal that the user finished the cooking celebration. ContentView will
  /// collapse the stack AND mark the cookAndRate quest as completed.
  func returnHomeAfterCooking() {
    didCompleteCooking = true
    shouldReturnHome = true
  }
}

/// Root host view for Home Dashboard and navigation flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToDemoMode = false
  @State private var navigateToDishEstimate = false
  @State private var showOnboarding = false
  @State private var showProfile = false
  @State private var navCoordinator = NavigationCoordinator()

  @AppStorage("tutorialProgressStorage") private var tutorialStorageString = ""

  var body: some View {
    NavigationStack {
      HomeDashboardView(
        deps: deps,
        onScan: openScan,
        onDemoMode: openDemoMode,
        onEstimate: openPreparedDishEstimate,
        onCompleteProfile: openOnboarding,
        onProfile: openProfile,
        onReset: performFullReset
      )
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $navigateToScan) {
        ScanView()
      }
      .navigationDestination(isPresented: $navigateToDemoMode) {
        DemoModeView()
      }
      .navigationDestination(isPresented: $navigateToDishEstimate) {
        PreparedDishEstimateView()
      }
    }
    .environment(navCoordinator)
    .flPageBackground()
    .onChange(of: navCoordinator.shouldReturnHome) { _, shouldReturn in
      guard shouldReturn else { return }

      // If cooking was completed, mark the quest before collapsing
      if navCoordinator.didCompleteCooking {
        markTutorialQuest(.cookAndRate)
        navCoordinator.didCompleteCooking = false
      }

      // Collapse the entire NavigationStack back to the Home dashboard
      navigateToScan = false
      navigateToDemoMode = false
      navigateToDishEstimate = false
      navCoordinator.shouldReturnHome = false
    }
    .task {
      await refreshOnboardingGate()
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingView(isRequired: !hasOnboarded) {
        showOnboarding = false
        // Mark Quest 1 (setupProfile) as completed
        markTutorialQuest(.setupProfile)
        Task { await refreshOnboardingGate() }
      }
      .interactiveDismissDisabled(!hasOnboarded)
      .environmentObject(deps)
    }
    .sheet(isPresented: $showProfile) {
      ProfileView()
        .environmentObject(deps)
    }
  }

  private func openScan() {
    if hasOnboarded {
      navigateToScan = true
    } else {
      showOnboarding = true
    }
  }

  private func openDemoMode() {
    // Mark Quest 2 (firstScan) when user enters demo mode
    markTutorialQuest(.firstScan)
    navigateToDemoMode = true
  }

  private func openPreparedDishEstimate() {
    // Mark Quest 4 (exploreMore) when user opens the estimate feature
    markTutorialQuest(.exploreMore)
    navigateToDishEstimate = true
  }

  private func openOnboarding() {
    showOnboarding = true
  }

  private func openProfile() {
    if hasOnboarded {
      showProfile = true
    } else {
      showOnboarding = true
    }
  }

  private func refreshOnboardingGate() async {
    do {
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
    } catch {
      // Gate refresh is non-critical.
    }
  }

  // MARK: - Tutorial Progress

  private func markTutorialQuest(_ quest: TutorialQuest) {
    var progress = TutorialProgress(storageString: tutorialStorageString)
    progress.markCompleted(quest)
    tutorialStorageString = progress.storageString
  }

  // MARK: - Full Reset

  private func performFullReset() {
    // 1. Clear all user data from the database
    do {
      try deps.userDataRepository.resetAllUserData()
    } catch {
      // Reset is best-effort; log but don't block the UI.
    }

    // 2. Clear tutorial progress (already cleared in HomeDashboardView,
    //    but ensure ContentView's copy is also empty)
    tutorialStorageString = ""

    // 3. Clear learning telemetry counters from UserDefaults
    UserDefaults.standard.removeObject(forKey: "learning_suggestions_shown")
    UserDefaults.standard.removeObject(forKey: "learning_suggestions_accepted")

    // 4. Refresh onboarding gate so the app knows profile is gone
    hasOnboarded = false
  }
}
