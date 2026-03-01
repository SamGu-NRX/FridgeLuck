import SwiftUI

/// Root host view for Home Dashboard and navigation flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToJudgeDemo = false
  @State private var navigateToDishEstimate = false
  @State private var navigateToScenarioDemo = false
  @State private var selectedDemoScenario: DemoScenario?
  @State private var showOnboarding = false
  @State private var showProfile = false

  @AppStorage("tutorialProgressStorage") private var tutorialStorageString = ""

  var body: some View {
    NavigationStack {
      HomeDashboardView(
        deps: deps,
        isRunningDemo: false,
        onStartJudgePath: runJudgePathFromDashboard,
        onScan: openScan,
        onRunDemo: runJudgePathFromDashboard,
        onEstimate: openPreparedDishEstimate,
        onCompleteProfile: openOnboarding,
        onProfile: openProfile,
        onSelectDemoScenario: openScenarioDemo
      )
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $navigateToScan) {
        ScanView()
      }
      .navigationDestination(isPresented: $navigateToJudgeDemo) {
        ScanView(mode: .demo, entryMode: .judgePath)
      }
      .navigationDestination(isPresented: $navigateToScenarioDemo) {
        if let scenario = selectedDemoScenario {
          ScanView(mode: .demo, entryMode: .judgePath, demoScenario: scenario)
        }
      }
      .navigationDestination(isPresented: $navigateToDishEstimate) {
        PreparedDishEstimateView()
      }
    }
    .flPageBackground()
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

  private func runJudgePathFromDashboard() {
    navigateToJudgeDemo = true
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

  private func openScenarioDemo(_ scenario: DemoScenario) {
    selectedDemoScenario = scenario
    // Mark Quest 2 (firstScan) when user picks a scenario
    markTutorialQuest(.firstScan)
    navigateToScenarioDemo = true
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
}
