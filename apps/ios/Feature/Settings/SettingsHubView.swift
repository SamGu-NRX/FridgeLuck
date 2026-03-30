import SwiftUI

struct SettingsHubView: View {
  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var phase1Appeared = false
  @State private var phase2Appeared = false
  @State private var phase3Appeared = false
  @State private var phase4Appeared = false

  var body: some View {
    @Bindable var boundPrefs = prefs

    Form {
      Section {
        appearanceSelector(selection: $boundPrefs.appearance)
          .listRowInsets(
            EdgeInsets(
              top: AppTheme.Space.sm, leading: AppTheme.Space.md,
              bottom: AppTheme.Space.sm, trailing: AppTheme.Space.md
            )
          )
          .listRowBackground(Color.clear)
      } header: {
        sectionHeader("Appearance")
      }
      .opacity(phase1Appeared ? 1 : 0)
      .offset(y: phase1Appeared ? 0 : 8)

      Section {
        Picker("Units", selection: $boundPrefs.measurementUnit) {
          ForEach(AppMeasurementUnit.allCases) { unit in
            Text(unit.displayName).tag(unit)
          }
        }
        .pickerStyle(.menu)
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
            if newValue { AppPreferencesStore.haptic(.light) }
          }
      } header: {
        sectionHeader("Preferences")
      }
      .opacity(phase2Appeared ? 1 : 0)
      .offset(y: phase2Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.profileBasics) {
          iconRow(icon: "person.fill", tint: AppTheme.accent, title: "Basics")
        }
        NavigationLink(value: SettingsRoute.nutritionTargets) {
          iconRow(icon: "target", tint: AppTheme.sage, title: "Targets")
        }
        NavigationLink(value: SettingsRoute.foodPreferences) {
          iconRow(icon: "leaf.fill", tint: AppTheme.oat, title: "Diet & Allergens")
        }
      } header: {
        sectionHeader("Profile & Nutrition")
      }
      .opacity(phase3Appeared ? 1 : 0)
      .offset(y: phase3Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.integrations) {
          iconRow(icon: "heart.fill", tint: AppTheme.sage, title: "Apple Health")
        }
        NavigationLink(value: SettingsRoute.permissions) {
          iconRow(icon: "lock.fill", tint: AppTheme.textSecondary, title: "Permissions")
        }
      } header: {
        sectionHeader("Connections")
      }
      .opacity(phase4Appeared ? 1 : 0)
      .offset(y: phase4Appeared ? 0 : 10)

      Section {
        NavigationLink(value: SettingsRoute.help) {
          iconRow(icon: "sparkles", tint: AppTheme.accentLight, title: "Help")
        }
        NavigationLink(value: SettingsRoute.dataAndPrivacy) {
          iconRow(icon: "shield.fill", tint: AppTheme.dustyRose, title: "Data & Privacy")
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
    .onAppear {
      guard !phase1Appeared else { return }
      if reduceMotion {
        phase1Appeared = true
        phase2Appeared = true
        phase3Appeared = true
        phase4Appeared = true
      } else {
        let interval = AppMotion.staggerInterval
        withAnimation(AppMotion.staggerEntrance) { phase1Appeared = true }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 2)) { phase2Appeared = true }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 4)) { phase3Appeared = true }
        withAnimation(AppMotion.staggerEntrance.delay(interval * 6)) { phase4Appeared = true }
      }
    }
  }

  // MARK: - Appearance Selector

  private func appearanceSelector(selection: Binding<AppAppearance>) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      ForEach(AppAppearance.allCases) { mode in
        let isSelected = selection.wrappedValue == mode

        Button {
          withAnimation(AppMotion.standard) { selection.wrappedValue = mode }
          AppPreferencesStore.haptic(.light)
        } label: {
          VStack(spacing: AppTheme.Space.xs) {
            miniPreview(for: mode)
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(isSelected ? AppTheme.accent : .clear, lineWidth: 2)
              )

            HStack(spacing: 4) {
              Image(systemName: mode.icon)
                .font(.system(size: 10, weight: .medium))
              Text(mode.displayName)
                .font(AppTheme.Typography.settingsCaptionMedium)
            }
            .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.displayName) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
  }

  @ViewBuilder
  private func miniPreview(for mode: AppAppearance) -> some View {
    switch mode {
    case .light:
      SettingsMiniAppPreview().environment(\.colorScheme, .light)
    case .dark:
      SettingsMiniAppPreview().environment(\.colorScheme, .dark)
    case .system:
      SettingsMiniAppPreview()
    }
  }

  // MARK: - Row Helpers

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(.subheadline, design: .serif, weight: .medium))
      .foregroundStyle(AppTheme.textSecondary)
      .textCase(nil)
  }

  private func iconRow(icon: String, tint: Color, title: String) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      Text(title)
        .font(AppTheme.Typography.settingsBody)
        .foregroundStyle(AppTheme.textPrimary)
    }
    .padding(.vertical, AppTheme.Space.xxxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
  }

  // MARK: - Helpers

  private var appVersion: String {
    let shortVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let buildNumber =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Version \(shortVersion) (\(buildNumber))"
  }
}

// MARK: - Mini App Preview

private struct SettingsMiniAppPreview: View {
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(AppTheme.textPrimary.opacity(0.4))
          .frame(width: 24, height: 4)
        Spacer()
        Circle()
          .fill(AppTheme.accent)
          .frame(width: 6, height: 6)
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 6)

      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(AppTheme.surface)
        .frame(height: 24)
        .padding(.horizontal, 8)

      Spacer().frame(height: 6)

      VStack(spacing: 3) {
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(AppTheme.textSecondary.opacity(0.2))
            .frame(height: 3)
          RoundedRectangle(cornerRadius: 1.5)
            .fill(AppTheme.sage.opacity(0.25))
            .frame(width: 14, height: 3)
        }
        .padding(.horizontal, 10)

        RoundedRectangle(cornerRadius: 1.5)
          .fill(AppTheme.textSecondary.opacity(0.12))
          .frame(height: 3)
          .padding(.horizontal, 10)
          .padding(.trailing, 18)
      }

      Spacer()

      HStack(spacing: 10) {
        ForEach(0..<3, id: \.self) { i in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(i == 1 ? AppTheme.accent.opacity(0.7) : AppTheme.textSecondary.opacity(0.15))
            .frame(width: 10, height: 3)
        }
      }
      .padding(.bottom, 8)
    }
    .frame(height: 86)
    .background(AppTheme.bg)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 0.5)
    )
  }
}
