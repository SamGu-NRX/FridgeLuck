import GRDB
import SwiftUI

/// Root view with navigation to Scan and Demo flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var ingredientCount: Int = 0
  @State private var recipeCount: Int = 0
  @State private var hasOnboarded: Bool = false

  @State private var navigateToScan = false
  @State private var navigateToDemo = false
  @State private var navigateToDishEstimate = false
  @State private var showOnboarding = false
  @State private var showEditProfile = false

  @State private var demoDetections: [Detection] = []
  @State private var isRunningDemo = false
  @State private var demoErrorMessage: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          heroSection
            .transition(.move(edge: .top).combined(with: .opacity))
          statsSection
            .transition(.opacity)
          actionSection
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.xl)
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if hasOnboarded {
            Button("Profile") {
              showEditProfile = true
            }
            .font(.subheadline.weight(.semibold))
          }
        }
      }
      .navigationDestination(isPresented: $navigateToScan) {
        ScanView()
      }
      .navigationDestination(isPresented: $navigateToDemo) {
        IngredientReviewView(detections: demoDetections)
      }
      .navigationDestination(isPresented: $navigateToDishEstimate) {
        PreparedDishEstimateView()
      }
    }
    .flPageBackground()
    .task {
      await loadStats()
    }
    .animation(reduceMotion ? nil : AppMotion.gentle, value: hasOnboarded)
    .animation(reduceMotion ? nil : AppMotion.gentle, value: isRunningDemo)
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

  private var heroSection: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text("FridgeLuck")
              .font(.system(.largeTitle, design: .rounded, weight: .bold))
              .foregroundStyle(AppTheme.textPrimary)
            Text("What you have is enough.")
              .font(.title3.weight(.medium))
              .foregroundStyle(AppTheme.textSecondary)
          }
          Spacer()
          Image(systemName: "refrigerator.fill")
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }

        Text(
          "Scan ingredients, confirm quickly, and jump straight into recipes built around your real fridge."
        )
        .font(.subheadline)
        .foregroundStyle(AppTheme.textSecondary)

        FLPrimaryButton("Start Cooking Now", systemImage: "camera.fill") {
          navigateToScan = true
        }

        if !hasOnboarded {
          FLSecondaryButton(
            "Complete Profile Setup", systemImage: "person.crop.circle.badge.exclamationmark"
          ) {
            showOnboarding = true
          }
        }
      }
    }
  }

  private var statsSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Your Kitchen Snapshot", subtitle: "Live bundle + profile status", icon: "chart.bar.fill")

        statRow(icon: "leaf.fill", label: "Ingredients", value: "\(ingredientCount)")
        statRow(icon: "book.fill", label: "Recipes", value: "\(recipeCount)")
        HStack {
          Label("Profile", systemImage: "person.crop.circle")
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          FLStatusPill(
            text: hasOnboarded ? "Complete" : "Needs setup",
            kind: hasOnboarded ? .positive : .warning)
        }
      }
    }
  }

  private var actionSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      FLSectionHeader(
        "More Ways to Start", subtitle: "Demo and fallback tools", icon: "square.grid.2x2")

      FLCard {
        VStack(spacing: AppTheme.Space.sm) {
          FLSecondaryButton(
            isRunningDemo ? "Running Demo..." : "Run Demo Scan",
            systemImage: isRunningDemo ? "hourglass" : "photo.fill",
            isEnabled: !isRunningDemo
          ) {
            Task { await runDemoScan() }
          }

          FLSecondaryButton(
            "Estimate Prepared Dish",
            systemImage: "fork.knife",
            isEnabled: !isRunningDemo
          ) {
            navigateToDishEstimate = true
          }

          if isRunningDemo {
            Text("Preparing fixture detections and nutrition OCR preview...")
              .font(.caption)
              .foregroundStyle(AppTheme.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private func statRow(icon: String, label: String, value: String) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(AppTheme.accent)
        .frame(width: 20)
      Text(label)
        .font(.subheadline)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
      Text(value)
        .font(.subheadline.bold())
        .foregroundStyle(AppTheme.textPrimary)
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
      // Stats are non-critical.
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
