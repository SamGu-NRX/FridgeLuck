import SwiftUI

private struct SettingsOverviewSnapshot {
  let profile: HealthProfile
  let hasCompletedOnboarding: Bool
  let tutorialProgress: TutorialProgress
  let appleHealthStatus: AppPermissionStatus
  let cameraStatus: AppPermissionStatus
  let microphoneStatus: AppPermissionStatus
  let photoStatus: AppPermissionStatus

  var summaryTitle: String {
    let trimmedName = profile.normalizedDisplayName
    return trimmedName.isEmpty ? "Finish your profile" : trimmedName
  }

  var summarySubtitle: String {
    let ageText = profile.age.map { "\($0) years old" } ?? "Age not set"
    return
      "\(profile.goal.displayName) \u{2022} \(profile.dailyCalories ?? profile.goal.suggestedCalories) kcal/day \u{2022} \(ageText)"
  }

  var summaryBadges: [FLSettingsBadge] {
    var items: [FLSettingsBadge] = [
      FLSettingsBadge(
        text: hasCompletedOnboarding ? "Profile complete" : "Needs attention",
        tone: hasCompletedOnboarding ? .positive : .warning
      ),
      FLSettingsBadge(
        text: profile.selectedDietID?.capitalized ?? "Classic",
        tone: .neutral
      ),
    ]

    if appleHealthStatus.isAllowedForSettings {
      items.append(FLSettingsBadge(text: "Apple Health connected", tone: .positive))
    } else {
      items.append(FLSettingsBadge(text: "Apple Health not connected", tone: .accent))
    }

    return items
  }

  var profileSummary: String {
    let name =
      profile.normalizedDisplayName.isEmpty ? "Name and age needed" : profile.normalizedDisplayName
    let age = profile.age.map(String.init) ?? "Age"
    return "\(name) \u{2022} \(age)"
  }

  var nutritionSummary: String {
    let calories = profile.dailyCalories ?? profile.goal.suggestedCalories
    return "\(profile.goal.displayName) \u{2022} \(calories) kcal \u{2022} \(macroSummary)"
  }

  var foodSummary: String {
    let diet = profile.selectedDietID?.capitalized ?? "Classic"
    let allergenCount = profile.parsedAllergenIds.count
    return allergenCount > 0
      ? "\(diet) \u{2022} \(allergenCount) allergen filters"
      : "\(diet) \u{2022} No allergen filters"
  }

  var integrationsSummary: String {
    appleHealthStatus.settingsLabel
  }

  var permissionsSummary: String {
    let allowedCount = [cameraStatus, microphoneStatus, photoStatus].filter {
      $0.isAllowedForSettings
    }
    .count
    return "\(allowedCount) of 3 allowed"
  }

  var appExperienceSummary: String {
    tutorialProgress.isComplete
      ? "Guided tour complete"
      : "\(tutorialProgress.completedCount) of \(TutorialQuest.allCases.count) tutorial steps complete"
  }

  var dataSummary: String {
    "Reset data, open system settings, and review local storage controls"
  }

  private var macroSummary: String {
    let protein = Int((profile.proteinPct * 100).rounded())
    let carbs = Int((profile.carbsPct * 100).rounded())
    let fat = Int((profile.fatPct * 100).rounded())
    return "P\(protein)/C\(carbs)/F\(fat)"
  }
}

struct SettingsHubView: View {
  @EnvironmentObject private var deps: AppDependencies
  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  let refreshID: Int

  @State private var snapshot = SettingsOverviewSnapshot(
    profile: .default,
    hasCompletedOnboarding: false,
    tutorialProgress: .empty,
    appleHealthStatus: .notDetermined,
    cameraStatus: .notDetermined,
    microphoneStatus: .notDetermined,
    photoStatus: .notDetermined
  )

  @State private var summaryAppeared = false
  @State private var sectionsAppeared = false

  var body: some View {
    @Bindable var boundPrefs = prefs

    Form {
      // MARK: - Summary Card

      Section {
        FLSettingsSummaryCard(
          title: snapshot.summaryTitle,
          subtitle: snapshot.summarySubtitle,
          badges: snapshot.summaryBadges
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
      }
      .opacity(summaryAppeared ? 1 : 0)
      .offset(y: summaryAppeared ? 0 : 8)

      // MARK: - Profile & Nutrition

      Section {
        NavigationLink(value: SettingsRoute.profileBasics) {
          FLSettingsDisclosureRow(
            title: "Basics",
            value: snapshot.profileSummary,
            subtitle: snapshot.hasCompletedOnboarding
              ? "Used for personalization and onboarding status."
              : "Complete this to unlock personalized recipe guidance."
          )
        }

        NavigationLink(value: SettingsRoute.nutritionTargets) {
          FLSettingsDisclosureRow(
            title: "Targets",
            value: snapshot.nutritionSummary,
            subtitle: "Goal, calories, and macro balance."
          )
        }

        NavigationLink(value: SettingsRoute.foodPreferences) {
          FLSettingsDisclosureRow(
            title: "Diet and allergens",
            value: snapshot.foodSummary,
            subtitle: "Recipe matching and safety filters."
          )
        }
      } header: {
        Label("Profile & Nutrition", systemImage: "person.crop.circle")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(nil)
      }
      .opacity(sectionsAppeared ? 1 : 0)
      .offset(y: sectionsAppeared ? 0 : 10)

      // MARK: - Preferences (inline controls)

      Section {
        Picker("Appearance", selection: $boundPrefs.appearance) {
          ForEach(AppAppearance.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden, edges: .bottom)
        .onChange(of: boundPrefs.appearance) { _, _ in
          AppPreferencesStore.haptic(.light)
        }

        Picker("Units", selection: $boundPrefs.measurementUnit) {
          ForEach(AppMeasurementUnit.allCases) { unit in
            Text(unit.displayName).tag(unit)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: boundPrefs.measurementUnit) { _, _ in
          AppPreferencesStore.haptic(.light)
        }

        Stepper(value: $boundPrefs.defaultServings, in: 1...10) {
          HStack {
            Text("Default Servings")
            Spacer()
            Text("\(boundPrefs.defaultServings)")
              .font(AppTheme.Typography.settingsDetail)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .onChange(of: boundPrefs.defaultServings) { _, _ in
          AppPreferencesStore.haptic(.light)
        }

        Toggle("Haptic Feedback", isOn: $boundPrefs.hapticsEnabled)
          .tint(AppTheme.accent)
          .onChange(of: boundPrefs.hapticsEnabled) { _, newValue in
            if newValue {
              AppPreferencesStore.haptic(.light)
            }
          }
      } header: {
        Label("Preferences", systemImage: "slider.horizontal.3")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(nil)
      } footer: {
        FLSettingsFootnote(text: "Appearance and units apply across the entire app.")
      }
      .opacity(sectionsAppeared ? 1 : 0)
      .offset(y: sectionsAppeared ? 0 : 10)

      // MARK: - Connections

      Section {
        NavigationLink(value: SettingsRoute.integrations) {
          FLSettingsDisclosureRow(
            title: "Integrations",
            value: snapshot.integrationsSummary,
            subtitle: "Apple Health nutrition sync."
          )
        }

        NavigationLink(value: SettingsRoute.permissions) {
          FLSettingsDisclosureRow(
            title: "Permissions",
            value: snapshot.permissionsSummary,
            subtitle: "Camera, microphone, and photo access."
          )
        }
      } header: {
        Label("Connections", systemImage: "link")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(nil)
      }
      .opacity(sectionsAppeared ? 1 : 0)
      .offset(y: sectionsAppeared ? 0 : 10)

      // MARK: - More

      Section {
        NavigationLink(value: SettingsRoute.appExperience) {
          FLSettingsDisclosureRow(
            title: "Guided experience",
            value: snapshot.appExperienceSummary,
            subtitle: "Replay onboarding and check tutorial progress."
          )
        }

        NavigationLink(value: SettingsRoute.dataAndPrivacy) {
          FLSettingsDisclosureRow(
            title: "Controls",
            value: "Manage",
            subtitle: snapshot.dataSummary
          )
        }
      } header: {
        Label("More", systemImage: "ellipsis.circle")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(nil)
      }
      .opacity(sectionsAppeared ? 1 : 0)
      .offset(y: sectionsAppeared ? 0 : 10)
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .task(id: refreshID) {
      await load()
    }
    .refreshable {
      await load()
    }
    .onAppear {
      guard !summaryAppeared else { return }
      if reduceMotion {
        summaryAppeared = true
        sectionsAppeared = true
      } else {
        withAnimation(AppMotion.tabEntrance) {
          summaryAppeared = true
        }
        withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 2)) {
          sectionsAppeared = true
        }
      }
    }
  }

  private func load() async {
    let profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    let hasCompletedOnboarding = (try? deps.userDataRepository.hasCompletedOnboarding()) ?? false
    let tutorialProgress = TutorialProgress(storageString: tutorialStorageString)

    snapshot = SettingsOverviewSnapshot(
      profile: profile,
      hasCompletedOnboarding: hasCompletedOnboarding,
      tutorialProgress: tutorialProgress,
      appleHealthStatus: deps.appleHealthService.authorizationStatus(),
      cameraStatus: AppPermissionCenter.status(for: .camera),
      microphoneStatus: AppPermissionCenter.status(for: .microphone),
      photoStatus: AppPermissionCenter.status(for: .photoLibraryReadWrite)
    )
  }
}
