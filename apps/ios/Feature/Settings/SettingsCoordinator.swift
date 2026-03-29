import Observation

@MainActor
@Observable
final class SettingsCoordinator {
  var path: [SettingsRoute] = []

  func open(_ route: SettingsRoute) {
    switch route {
    case .overview:
      path.removeAll()
    default:
      path = [route]
    }
  }

  func push(_ route: SettingsRoute) {
    guard route != .overview else {
      open(.overview)
      return
    }
    path.append(route)
  }

  func reset() {
    path.removeAll()
  }
}
