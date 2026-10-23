import Foundation
import FLFeatureLogic
import Observation

/// Presents the plan sheet from an entry point. Every opening builds a new view model, so the
/// sheet reads the kitchen as it is at that moment instead of a plan left over from earlier.
@MainActor
@Observable
final class PlanSheetLauncher {
  struct Session: Identifiable {
    let id = UUID()
    let model: PlanSheetViewModel
  }

  /// Non-nil while the sheet is up; the presenting view binds `.sheet(item:)` to it.
  var session: Session?

  private let makeModel: @MainActor () -> PlanSheetViewModel
  private var afterDismiss: (() -> Void)?

  init(makeModel: @escaping @MainActor () -> PlanSheetViewModel) {
    self.makeModel = makeModel
  }

  func open() {
    session = Session(model: makeModel())
  }

  /// Closes the sheet and runs `action` once it is gone, so a navigation push from the sheet
  /// ("Add groceries") does not race the dismissal.
  func close(then action: @escaping () -> Void) {
    afterDismiss = action
    session = nil
  }

  /// The sheet's `onDismiss`.
  func sheetDidDismiss() {
    let action = afterDismiss
    afterDismiss = nil
    action?()
  }
}
