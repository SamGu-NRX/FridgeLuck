import Combine
import Foundation
import GRDB

// The observable state holder for the operational Home flow (FL4).
//
// A thin shell: all logic it needs is either the pure state map
// (`HomeFlowStateMap`) or the pure generation guard (`HomeLoadGeneration`), both
// tested on Linux by the home-flow-check package against the real repositories.
// This file holds published state, wires GRDB live updates, and nothing else —
// it is not part of the Linux check target because Combine's ObservableObject
// does not exist there. No tutorial progress is read anywhere in this file.

@MainActor
final class HomeFlowViewModel: ObservableObject {
  /// State-map inputs from the latest successful load; nil until then (the gate
  /// maps nil to the error state, which is what a cold-start failure shows).
  @Published private(set) var inputs: HomeFlowInputs?
  /// The dashboard sections' snapshot from the same load as `inputs`.
  @Published private(set) var snapshot: HomeDashboardSnapshot?
  /// The view-supplied Live Assistant context; non-nil means a cook is live.
  @Published var cookContext: HomeCookContext?
  @Published private(set) var isLoading = false
  /// Set when a load fails; the gate maps a nil `inputs` to the error state, and a
  /// failure with existing inputs keeps the last good dashboard on screen.
  @Published private(set) var errorMessage: String?

  private let reader: any HomeFlowReading
  private var generation = HomeLoadGeneration()
  private var cancellables: [AnyDatabaseCancellable] = []

  /// The production initializer: reads through the real repositories and reloads
  /// on the same GRDB change observations Home has always used (cooking history
  /// and inventory — a scan can change recommendations and use-soon alerts
  /// without touching history).
  init(readModel: HomeFlowReadModel) {
    self.reader = readModel
    wireLiveUpdates(readModel)
  }

  /// Test seam in the app target (SwiftUI previews / XCUI harnesses): read through
  /// any `HomeFlowReading`, with no live observers wired.
  init(reader: any HomeFlowReading) {
    self.reader = reader
  }

  /// Generation-guarded load: a stale completion never touches published state,
  /// so a slow early load cannot clobber a newer one's result.
  func load() async {
    let myGeneration = generation.begin()
    isLoading = true

    do {
      let result = try await reader.load()
      guard generation.isCurrent(myGeneration) else { return }
      inputs = result.inputs
      snapshot = result.snapshot
      errorMessage = nil
      isLoading = false
    } catch {
      guard generation.isCurrent(myGeneration) else { return }
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  func retry() async {
    await load()
  }

  private func wireLiveUpdates(_ readModel: HomeFlowReadModel) {
    cancellables.append(
      readModel.userData.observeCookingHistoryChanges(
        onError: { _ in },
        onChange: { [weak self] in
          guard let self else { return }
          Task { await self.load() }
        }
      )
    )
    cancellables.append(
      readModel.inventory.observeInventoryChanges(
        onError: { _ in },
        onChange: { [weak self] in
          guard let self else { return }
          Task { await self.load() }
        }
      )
    )
  }
}
