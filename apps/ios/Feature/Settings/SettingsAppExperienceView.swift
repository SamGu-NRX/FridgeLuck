import SwiftUI

struct SettingsAppExperienceView: View {
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  let onReplayOnboarding: () -> Void

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
  }

  var body: some View {
    Form {
      Section("Guided Experience") {
        FLSettingsStatusRow(
          title: "Tutorial progress",
          status: tutorialProgress.isComplete ? "Complete" : "In progress",
          detail: tutorialProgress.isComplete
            ? "All guided steps are complete."
            : "\(tutorialProgress.completedCount) of \(TutorialQuest.allCases.count) tutorial steps are finished.",
          badge: FLSettingsBadge(
            text: tutorialProgress.isComplete ? "Done" : "Active",
            tone: tutorialProgress.isComplete ? .positive : .accent
          )
        )

        FLSettingsStatusRow(
          title: "First-run onboarding",
          status: firstRunExperienceStore.hasCompletedCurrentVersion ? "Completed" : "Pending",
          detail:
            "Replay the onboarding flow if you want to revisit setup guidance and Apple Health prompts.",
          badge: FLSettingsBadge(
            text: firstRunExperienceStore.hasCompletedCurrentVersion ? "Seen" : "Pending",
            tone: firstRunExperienceStore.hasCompletedCurrentVersion ? .neutral : .warning
          )
        )

        Button("Replay onboarding") {
          onReplayOnboarding()
        }
      }
    }
    .scrollContentBackground(.hidden)
    .navigationTitle("App Experience")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground(renderMode: .interactive)
  }
}
