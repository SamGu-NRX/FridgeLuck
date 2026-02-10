import GRDB
import SwiftUI

/// Root view with navigation to Scan and Demo flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var ingredientCount: Int = 0
  @State private var recipeCount: Int = 0
  @State private var hasOnboarded: Bool = false

  @State private var navigateToScan = false
  @State private var navigateToDemo = false
  @State private var showOnboarding = false
  @State private var showEditProfile = false

  @State private var demoDetections: [Detection] = []
  @State private var isRunningDemo = false
  @State private var demoErrorMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        // Header
        VStack(spacing: 8) {
          Image(systemName: "refrigerator.fill")
            .font(.system(size: 64))
            .foregroundStyle(.yellow)
          Text("FridgeLuck")
            .font(.largeTitle.bold())
          Text("What you have is enough.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 40)

        Divider()

        // Stats
        VStack(spacing: 12) {
          StatRow(icon: "leaf.fill", label: "Ingredients", value: "\(ingredientCount)")
          StatRow(icon: "book.fill", label: "Recipes", value: "\(recipeCount)")
          StatRow(icon: "heart.fill", label: "Onboarded", value: hasOnboarded ? "Yes" : "Not yet")
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

        Spacer()

        // Actions
        VStack(spacing: 12) {
          Button {
            navigateToScan = true
          } label: {
            Label("Scan Fridge", systemImage: "camera.fill")
              .frame(maxWidth: .infinity)
              .padding()
              .background(.yellow)
              .foregroundStyle(.black)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .font(.headline)
          }

          Button {
            Task { await runDemoScan() }
          } label: {
            HStack(spacing: 8) {
              if isRunningDemo {
                ProgressView()
                  .tint(.primary)
              }
              Label("Demo Mode", systemImage: "photo.fill")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.gray.opacity(0.2))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .font(.headline)
          }
          .disabled(isRunningDemo)
        }
        .padding(.horizontal)
        .padding(.bottom, 32)
      }
      .padding(.horizontal)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if hasOnboarded {
            Button("Profile") {
              showEditProfile = true
            }
          }
        }
      }
      .navigationDestination(isPresented: $navigateToScan) {
        ScanView()
      }
      .navigationDestination(isPresented: $navigateToDemo) {
        IngredientReviewView(detections: demoDetections)
      }
    }
    .task {
      await loadStats()
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      OnboardingView(isRequired: true) {
        showOnboarding = false
        Task { await loadStats() }
      }
      .interactiveDismissDisabled(true)
      .environmentObject(deps)
    }
    .sheet(isPresented: $showEditProfile) {
      OnboardingView(isRequired: false) {
        Task { await loadStats() }
      }
      .environmentObject(deps)
    }
    .alert(
      "Demo Mode",
      isPresented: Binding(
        get: { demoErrorMessage != nil },
        set: { show in
          if !show { demoErrorMessage = nil }
        }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(demoErrorMessage ?? "")
    }
  }

  private func loadStats() async {
    do {
      ingredientCount = try deps.ingredientRepository.count()
      recipeCount = try await deps.appDatabase.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
      }
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
      showOnboarding = !hasOnboarded
    } catch {
      // Stats are non-critical
    }
  }

  private func runDemoScan() async {
    isRunningDemo = true
    demoErrorMessage = nil

    let detections = await DemoScanService.loadDetections(using: deps.visionService)

    isRunningDemo = false
    guard !detections.isEmpty else {
      demoErrorMessage = "Demo scan fixture is unavailable."
      return
    }

    demoDetections = detections
    navigateToDemo = true
  }
}

// MARK: - Stat Row

private struct StatRow: View {
  let icon: String
  let label: String
  let value: String

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.yellow)
        .frame(width: 24)
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.semibold)
    }
  }
}
