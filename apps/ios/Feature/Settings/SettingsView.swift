import SwiftUI

#if canImport(HealthKitUI)
  import HealthKitUI
#endif

struct SettingsView: View {
  @EnvironmentObject private var deps: AppDependencies
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore
  @Bindable var coordinator: SettingsCoordinator

  let onProfileChanged: () -> Void
  let onResetAllData: () -> Void

  @State private var showReplayOnboarding = false
  @State private var appleHealthRequestTrigger = 0
  @State private var refreshID = 0

  var body: some View {
    NavigationStack(path: $coordinator.path) {
      SettingsHubView()
        .navigationDestination(for: SettingsRoute.self) { route in
          switch route {
          case .overview:
            SettingsHubView()
          case .profileBasics:
            SettingsProfileBasicsView {
              handleProfileMutation()
            }
          case .nutritionTargets:
            SettingsNutritionTargetsView {
              handleProfileMutation()
            }
          case .foodPreferences:
            SettingsFoodPreferencesView {
              handleProfileMutation()
            }
          case .integrations:
            SettingsIntegrationsView(
              refreshID: refreshID,
              onRequestAppleHealth: requestAppleHealthAccess
            )
          case .permissions:
            SettingsPermissionsView()
          case .help:
            SettingsHelpView {
              showReplayOnboarding = true
            }
          case .dataAndPrivacy:
            SettingsDataAndPrivacyView(onResetAllData: onResetAllData)
          }
        }
    }
    .fullScreenCover(isPresented: $showReplayOnboarding) {
      OnboardingView(isRequired: false) {
        firstRunExperienceStore.markCompletedCurrentVersion()
        showReplayOnboarding = false
        handleProfileMutation()
      }
      .environmentObject(deps)
    }
    .applyAppleHealthAuthorizationRequest(
      deps: deps,
      trigger: appleHealthRequestTrigger,
      onCompletion: {
        refreshID += 1
      }
    )
  }

  private func requestAppleHealthAccess() {
    appleHealthRequestTrigger += 1
  }

  private func handleProfileMutation() {
    refreshID += 1
    onProfileChanged()
  }
}

extension View {
  @ViewBuilder
  fileprivate func applyAppleHealthAuthorizationRequest(
    deps: AppDependencies,
    trigger: Int,
    onCompletion: @escaping @MainActor () -> Void
  ) -> some View {
    #if canImport(HealthKitUI)
      if let context = deps.appleHealthAuthorizationContext {
        self.healthDataAccessRequest(
          store: context.healthStore,
          shareTypes: context.requestShareTypes,
          readTypes: context.requestReadTypes,
          trigger: trigger
        ) { _ in
          Task { @MainActor in
            onCompletion()
          }
        }
      } else {
        self
      }
    #else
      self
    #endif
  }
}
