import SwiftUI

/// Root host view for Home Dashboard and navigation flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToDemo = false
  @State private var navigateToDishEstimate = false
  @State private var showOnboarding = false
  @State private var showProfile = false

  var body: some View {
    NavigationStack {
      HomeDashboardView(
        deps: deps,
        isRunningDemo: false,
        onScan: openScan,
        onRunDemo: runDemoFromDashboard,
        onEstimate: openPreparedDishEstimate,
        onCompleteProfile: openOnboarding,
        onProfile: openProfile
      )
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $navigateToScan) {
        ScanView()
      }
      .navigationDestination(isPresented: $navigateToDemo) {
        ScanView(mode: .demo)
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
    navigateToScan = true
  }

  private func runDemoFromDashboard() {
    navigateToDemo = true
  }

  private func openPreparedDishEstimate() {
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
      showOnboarding = !hasOnboarded
    } catch {
      // Gate refresh is non-critical.
    }
  }
}
