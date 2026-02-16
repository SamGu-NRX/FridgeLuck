import SwiftUI

/// Root view with navigation to Scan and Demo flows.
struct ContentView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var ingredientCount: Int = 0
  @State private var recipeCount: Int = 0
  @State private var hasOnboarded: Bool = false
  @State private var navigateToScan = false
  @State private var navigateToDemo = false

  /// Demo ingredients: egg, rice, soy sauce, chicken, onion, garlic
  private let demoIngredientIds: Set<Int64> = [1, 2, 3, 4, 5, 6]

  /// Demo detections for the ingredient review screen
  private var demoDetections: [Detection] {
    [
      Detection(
        ingredientId: 1, label: "Egg", confidence: 0.92, source: .vision, originalVisionLabel: "egg"
      ),
      Detection(
        ingredientId: 2, label: "Rice", confidence: 0.88, source: .vision,
        originalVisionLabel: "rice"),
      Detection(
        ingredientId: 3, label: "Soy Sauce", confidence: 0.85, source: .ocr,
        originalVisionLabel: "soy sauce"),
      Detection(
        ingredientId: 4, label: "Chicken Breast", confidence: 0.78, source: .vision,
        originalVisionLabel: "chicken"),
      Detection(
        ingredientId: 5, label: "Onion", confidence: 0.95, source: .vision,
        originalVisionLabel: "onion"),
      Detection(
        ingredientId: 6, label: "Garlic", confidence: 0.55, source: .vision,
        originalVisionLabel: "garlic"),
      Detection(
        ingredientId: 8, label: "Bell Pepper", confidence: 0.42, source: .vision,
        originalVisionLabel: "bell_pepper"),
      Detection(
        ingredientId: 21, label: "Green Onion", confidence: 0.30, source: .vision,
        originalVisionLabel: "chives"),
    ]
  }

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
            navigateToDemo = true
          } label: {
            Label("Demo Mode", systemImage: "photo.fill")
              .frame(maxWidth: .infinity)
              .padding()
              .background(.gray.opacity(0.2))
              .foregroundStyle(.primary)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .font(.headline)
          }
        }
        .padding(.horizontal)
        .padding(.bottom, 32)
      }
      .padding(.horizontal)
      .navigationBarTitleDisplayMode(.inline)
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
  }

  private func loadStats() async {
    do {
      ingredientCount = try deps.ingredientRepository.count()
      recipeCount = try await deps.appDatabase.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
      }
      hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
    } catch {
      // Stats are non-critical
    }
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
