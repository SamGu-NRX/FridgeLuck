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

// MARK: - App Tab

enum AppTab: Sendable {
  case home
  case dashboard
}

/// Root host view with permanent Home / Scan / Dashboard tab shell.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var selectedTab: AppTab = .home
  @State private var hasOnboarded = false
  @State private var navigateToScan = false
  @State private var navigateToDemoMode = false
  @State private var showOnboarding = false
  @State private var showProfile = false
  @State private var navCoordinator = NavigationCoordinator()
  @State private var navAppeared = false
  @State private var homeRefreshTrigger = 0
  @State private var spotlightCoordinator = SpotlightCoordinator()

  @AppStorage("tutorialProgressStorage") private var tutorialStorageString = ""

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
  }

  /// The shell nav should appear on top-level tab surfaces, not within pushed task flows.
  private var shouldShowBottomNav: Bool {
    switch selectedTab {
    case .home:
      return !navigateToScan && !navigateToDemoMode
    case .dashboard:
      return true
    }
  }

  var body: some View {
    ZStack {
      NavigationStack {
        HomeDashboardView(
          deps: deps,
          onScan: openScan,
          onDemoMode: openDemoMode,
          onCompleteProfile: openOnboarding,
          onExploreComplete: completeExploreQuest,
          onReset: performFullReset,
          refreshTrigger: homeRefreshTrigger,
          spotlightCoordinator: spotlightCoordinator
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToScan) {
          ScanView()
        }
        .navigationDestination(isPresented: $navigateToDemoMode) {
          DemoModeView()
        }
      }
      .environment(navCoordinator)
      .opacity(selectedTab == .home ? 1 : 0)
      .zIndex(selectedTab == .home ? 1 : 0)
      .allowsHitTesting(selectedTab == .home)

      if tutorialProgress.isComplete {
        NavigationStack {
          DashboardView(isTabEmbedded: true)
        }
        .environmentObject(deps)
        .opacity(selectedTab == .dashboard ? 1 : 0)
        .zIndex(selectedTab == .dashboard ? 1 : 0)
        .allowsHitTesting(selectedTab == .dashboard)
      }
    }
    .flPageBackground()
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if shouldShowBottomNav {
        bottomNav
          .opacity(navAppeared ? 1 : 0)
          .offset(y: navAppeared ? AppTheme.Home.navBaseOffset : AppTheme.Home.navBaseOffset + 20)
          .animation(reduceMotion ? nil : AppMotion.standard, value: navAppeared)
      }
    }
    .overlay {
      if let steps = spotlightCoordinator.activeSteps,
        selectedTab == .home, !navigateToScan, !navigateToDemoMode
      {
        SpotlightTutorialOverlay(
          steps: steps,
          anchors: spotlightCoordinator.anchors,
          isPresented: Binding(
            get: { spotlightCoordinator.activeSteps != nil },
            set: { isPresented in
              if !isPresented {
                spotlightCoordinator.activeSteps = nil
              }
            }
          ),
          onScrollToAnchor: spotlightCoordinator.onScrollToAnchor
        )
        .ignoresSafeArea()
      }
    }
    .onChange(of: navCoordinator.shouldReturnHome) { _, shouldReturn in
      guard shouldReturn else { return }

      if navCoordinator.didCompleteCooking {
        markTutorialQuest(.cookAndRate)
        navCoordinator.didCompleteCooking = false
        homeRefreshTrigger += 1
      }

      navigateToScan = false
      navigateToDemoMode = false
      selectedTab = .home
      navCoordinator.shouldReturnHome = false
    }
    .onChange(of: navigateToDemoMode) { wasNavigating, isNavigating in
      if wasNavigating && !isNavigating && !tutorialProgress.isCompleted(.firstScan) {
        markTutorialQuest(.firstScan)
      }
    }
    .task {
      await refreshOnboardingGate()
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingView(isRequired: !hasOnboarded) {
        showOnboarding = false
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
    .onAppear {
      if reduceMotion {
        navAppeared = true
      } else if !navAppeared {
        withAnimation(AppMotion.standard.delay(0.22)) {
          navAppeared = true
        }
      }
    }
  }

  // MARK: - Navigation Actions

  private func openScan() {
    if hasOnboarded {
      selectedTab = .home
      navigateToScan = true
    } else {
      showOnboarding = true
    }
  }

  private func openDemoMode() {
    selectedTab = .home
    navigateToDemoMode = true
  }

  private func completeExploreQuest() {
    markTutorialQuest(.exploreMore)
  }

  private func openOnboarding() {
    showOnboarding = true
  }

  private func openDashboardTab() {
    if hasOnboarded && tutorialProgress.isComplete {
      selectedTab = .dashboard
    } else if hasOnboarded {
      showProfile = true
    } else {
      showOnboarding = true
    }
  }

  private func refreshOnboardingGate() async {
    do {
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
    } catch {}
  }

  // MARK: - Tutorial Progress

  private func markTutorialQuest(_ quest: TutorialQuest) {
    var progress = TutorialProgress(storageString: tutorialStorageString)
    progress.markCompleted(quest)
    tutorialStorageString = progress.storageString
  }

  // MARK: - Full Reset

  private func performFullReset() {
    do {
      try deps.userDataRepository.resetAllUserData()
    } catch {}

    tutorialStorageString = ""
    spotlightCoordinator.activeSteps = nil

    UserDefaults.standard.removeObject(forKey: "learning_suggestions_shown")
    UserDefaults.standard.removeObject(forKey: "learning_suggestions_accepted")
    UserDefaults.standard.removeObject(forKey: "hasSeenSpotlightTutorial")
    UserDefaults.standard.removeObject(forKey: "hasSeenCompletionSpotlight")
    UserDefaults.standard.removeObject(forKey: "hasSeenReviewSpotlight")
    UserDefaults.standard.removeObject(forKey: "hasSeenSwapTooltip")
    UserDefaults.standard.removeObject(forKey: "hasSeenFirstScanNudge")
    UserDefaults.standard.removeObject(forKey: "hasSeenDemoSpotlight")

    hasOnboarded = false
    selectedTab = .home
  }

  // MARK: - Bottom Navigation

  private var bottomNav: some View {
    ZStack(alignment: .top) {
      HStack(spacing: 0) {
        navItem(
          icon: "house.fill",
          label: "Home",
          isActive: selectedTab == .home
        ) {
          selectedTab = .home
        }

        Spacer(minLength: AppTheme.Home.navCenterGap)

        navItem(
          icon: hasOnboarded
            ? (tutorialProgress.isComplete
              ? "chart.bar.doc.horizontal.fill"
              : "person.crop.circle.fill")
            : "person.badge.plus",
          label: tutorialProgress.isComplete ? "Dashboard" : "Profile",
          isActive: selectedTab == .dashboard
        ) {
          openDashboardTab()
        }
      }
      .padding(.horizontal, AppTheme.Space.lg)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.sm)
      .frame(maxWidth: .infinity)
      .background {
        RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          .fill(AppTheme.bg.opacity(0.92))
          .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: AppTheme.Home.navCornerRadius, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.24), lineWidth: 1)
      }
      .shadow(color: AppTheme.Shadow.colorDeep.opacity(0.45), radius: 14, x: 0, y: 5)

      Button(action: openScan) {
        Image(systemName: "camera.fill")
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: AppTheme.Home.orbSize, height: AppTheme.Home.orbSize)
          .background(AppTheme.accent, in: Circle())
          .overlay(Circle().stroke(AppTheme.surface.opacity(0.45), lineWidth: 1))
          .shadow(color: AppTheme.accent.opacity(0.34), radius: 18, x: 0, y: 8)
      }
      .buttonStyle(FLNavOrbButtonStyle())
      .offset(y: -AppTheme.Home.navOrbLift)
      .accessibilityLabel("Scan your fridge")
    }
    .padding(.horizontal, AppTheme.Home.navHorizontalInset)
    .padding(.top, AppTheme.Space.xs + AppTheme.Home.navOrbLift)
    .padding(.bottom, 0)
  }

  private func navItem(
    icon: String,
    label: String,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: AppTheme.Space.xxxs) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .medium))
        Text(label)
          .font(AppTheme.Typography.labelSmall)
      }
      .foregroundStyle(isActive ? AppTheme.accent : AppTheme.textSecondary)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(FLNavItemButtonStyle())
  }
}

// MARK: - Button Styles

private struct FLNavOrbButtonStyle: SwiftUI.ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}

private struct FLNavItemButtonStyle: SwiftUI.ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.80 : 1)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(reduceMotion ? nil : AppMotion.quick, value: configuration.isPressed)
  }
}
