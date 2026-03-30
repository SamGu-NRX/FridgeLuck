import SwiftUI

private struct SettingsOverviewSnapshot {
  let profile: HealthProfile
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

  var profileSummary: String {
    let name =
      profile.normalizedDisplayName.isEmpty ? "Not set" : profile.normalizedDisplayName
    let age = profile.age.map(String.init) ?? "—"
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
      ? "\(diet) \u{2022} \(allergenCount) allergens"
      : "\(diet) \u{2022} No allergens"
  }

  var integrationsSummary: String {
    appleHealthStatus.settingsLabel
  }

  var permissionsSummary: String {
    let allowedCount = [cameraStatus, microphoneStatus, photoStatus].filter {
      $0.isAllowedForSettings
    }
    .count
    return "\(allowedCount) of 3"
  }

  var appExperienceSummary: String {
    tutorialProgress.isComplete
      ? "Complete"
      : "\(tutorialProgress.completedCount) of \(TutorialQuest.allCases.count)"
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
    tutorialProgress: .empty,
    appleHealthStatus: .notDetermined,
    cameraStatus: .notDetermined,
    microphoneStatus: .notDetermined,
    photoStatus: .notDetermined
  )

  @State private var phase1Appeared = false
  @State private var phase2Appeared = false
  @State private var phase3Appeared = false
  @State private var phase4Appeared = false

  var body: some View {
    @Bindable var boundPrefs = prefs

    Form {
      Section {
        FLSettingsSummaryCard(
          title: snapshot.summaryTitle,
          subtitle: snapshot.summarySubtitle
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
      }
      .opacity(phase1Appeared ? 1 : 0)
      .offset(y: phase1Appeared ? 0 : 8)

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
        sectionHeader("Preferences")
      }
      .opacity(phase2Appeared ? 1 : 0)
      .offset(y: phase2Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.profileBasics) {
          iconRow(
            icon: "person.fill",
            tint: AppTheme.accent,
            title: "Basics",
            value: snapshot.profileSummary
          )
        }

        NavigationLink(value: SettingsRoute.nutritionTargets) {
          iconRow(
            icon: "target",
            tint: AppTheme.sage,
            title: "Targets",
            value: snapshot.nutritionSummary
          )
        }

        NavigationLink(value: SettingsRoute.foodPreferences) {
          iconRow(
            icon: "leaf.fill",
            tint: AppTheme.oat,
            title: "Diet and allergens",
            value: snapshot.foodSummary
          )
        }
      } header: {
        sectionHeader("Profile & Nutrition")
      }
      .opacity(phase3Appeared ? 1 : 0)
      .offset(y: phase3Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.integrations) {
          iconRow(
            icon: "heart.fill",
            tint: AppTheme.sage,
            title: "Apple Health",
            value: snapshot.integrationsSummary
          )
        }

        NavigationLink(value: SettingsRoute.permissions) {
          iconRow(
            icon: "lock.fill",
            tint: AppTheme.textSecondary,
            title: "Permissions",
            value: snapshot.permissionsSummary
          )
        }
      } header: {
        sectionHeader("Connections")
      }
      .opacity(phase4Appeared ? 1 : 0)
      .offset(y: phase4Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.appExperience) {
          iconRow(
            icon: "sparkles",
            tint: AppTheme.accentLight,
            title: "Guided experience",
            value: snapshot.appExperienceSummary
          )
        }

        NavigationLink(value: SettingsRoute.dataAndPrivacy) {
          iconRow(
            icon: "shield.fill",
            tint: AppTheme.dustyRose,
            title: "Data & Privacy"
          )
        }
      } header: {
        sectionHeader("More")
      } footer: {
        Text(appVersion)
          .font(AppTheme.Typography.settingsCaption)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
          .frame(maxWidth: .infinity)
          .padding(.top, AppTheme.Space.lg)
          .padding(.bottom, AppTheme.Home.navOrbLift)
      }
      .opacity(phase4Appeared ? 1 : 0)
      .offset(y: phase4Appeared ? 0 : 10)
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
      guard !phase1Appeared else { return }
      if reduceMotion {
        phase1Appeared = true
        phase2Appeared = true
        phase3Appeared = true
        phase4Appeared = true
      } else {
        let interval = AppMotion.staggerInterval
        withAnimation(AppMotion.staggerEntrance) {
          phase1Appeared = true
        }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 2)) {
          phase2Appeared = true
        }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 4)) {
          phase3Appeared = true
        }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 6)) {
          phase4Appeared = true
        }
      }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(.subheadline, design: .serif, weight: .medium))
      .foregroundStyle(AppTheme.textSecondary)
      .textCase(nil)
  }

  private func iconRow(
    icon: String,
    tint: Color,
    title: String,
    value: String = ""
  ) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      Text(title)
        .font(AppTheme.Typography.settingsBody)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer(minLength: AppTheme.Space.xs)

      if !value.isEmpty {
        Text(value)
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.trailing)
          .lineLimit(1)
      }
    }
    .padding(.vertical, AppTheme.Space.xxxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)\(value.isEmpty ? "" : ", \(value)")")
  }

  private var appVersion: String {
    let shortVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let buildNumber =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Version \(shortVersion) (\(buildNumber))"
  }

  private func load() async {
    let profile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
    let tutorialProgress = TutorialProgress(storageString: tutorialStorageString)

    snapshot = SettingsOverviewSnapshot(
      profile: profile,
      tutorialProgress: tutorialProgress,
      appleHealthStatus: deps.appleHealthService.authorizationStatus(),
      cameraStatus: AppPermissionCenter.status(for: .camera),
      microphoneStatus: AppPermissionCenter.status(for: .microphone),
      photoStatus: AppPermissionCenter.status(for: .photoLibraryReadWrite)
    )
  }
}
