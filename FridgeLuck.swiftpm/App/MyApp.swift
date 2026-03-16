import SwiftUI

@main
struct FridgeLuckApp: App {
  @State private var dependencies: AppDependencies?
  @State private var loadError: Error?

  init() {
    #if DEBUG
      Self.resetTutorialStateForLaunch()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let dependencies {
          ContentView()
            .environmentObject(dependencies)
        } else if let loadError {
          ErrorView(error: loadError)
        } else {
          LoadingView()
        }
      }
      .task {
        do {
          let appDB = try await AppDatabase.setup()
          await MainActor.run {
            self.dependencies = AppDependencies(appDatabase: appDB)
          }
        } catch {
          await MainActor.run {
            self.loadError = error
          }
        }
      }
    }
  }

  /// Keeps guided tours replayable on every debug launch.
  private static func resetTutorialStateForLaunch() {
    let defaults = UserDefaults.standard
    for key in TutorialStorageKeys.all {
      defaults.removeObject(forKey: key)
    }
  }
}

// MARK: - Loading View

private struct LoadingView: View {
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text("Setting up FridgeLuck...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Error View

private struct ErrorView: View {
  let error: Error

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.yellow)
      Text("Something went wrong")
        .font(.title2.bold())
      Text(error.localizedDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
  }
}
