import SwiftUI

@MainActor
@Observable
final class TutorialFlowContext {
  private(set) var activeQuest: TutorialQuest?
  private(set) var assignedScenario: DemoScenario?
  private(set) var questObjectiveCompleted = false

  var isActive: Bool { activeQuest != nil }

  func beginQuest(_ quest: TutorialQuest) {
    activeQuest = quest
    assignedScenario = quest.assignedScenario
    questObjectiveCompleted = false
  }

  func completeObjective() {
    guard activeQuest != nil, !questObjectiveCompleted else { return }
    questObjectiveCompleted = true
  }

  func reset() {
    activeQuest = nil
    assignedScenario = nil
    questObjectiveCompleted = false
  }
}
