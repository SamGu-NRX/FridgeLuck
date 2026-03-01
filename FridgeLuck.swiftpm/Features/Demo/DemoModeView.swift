import SwiftUI

/// Unified demo hub — users pick a fridge scenario or use their own photo.
/// Replaces the old `DemoScenarioPicker` embedded in the tutorial home
/// with a dedicated, full-page experience.
struct DemoModeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - State

  @State private var appeared = false
  @State private var loadingScenario: DemoScenario?
  @State private var loadedDetections: [Detection] = []
  @State private var loadedProvenance: ScanProvenance = .bundledFixture
  @State private var navigateToReview = false
  @State private var navigateToScan = false

  // MARK: - Layout

  private let columns = [
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
  ]

  // MARK: - Body

  var body: some View {
    ZStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
          header
            .padding(.horizontal, AppTheme.Space.page)

          scenarioGrid
            .padding(.horizontal, AppTheme.Space.page)

          ownPhotoCard
            .padding(.horizontal, AppTheme.Space.page)
        }
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }

      // Loading overlay
      if let scenario = loadingScenario {
        scenarioLoadingOverlay(scenario)
          .transition(.opacity)
      }
    }
    .navigationTitle("Try FridgeLuck")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: loadedDetections,
        scanProvenance: loadedProvenance
      )
    }
    .navigationDestination(isPresented: $navigateToScan) {
      ScanView(mode: .live)
    }
    .onAppear {
      guard !reduceMotion, !appeared else {
        appeared = true
        return
      }
      withAnimation(AppMotion.heroAppear.delay(0.1)) {
        appeared = true
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text("Try FridgeLuck")
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Text("Pick a pre-stocked fridge to explore, or snap your own photo.")
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
  }

  // MARK: - Scenario Grid

  private var scenarioGrid: some View {
    LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
      ForEach(Array(DemoScenario.allCases.enumerated()), id: \.element.id) { index, scenario in
        scenarioCard(scenario, index: index)
      }
    }
  }

  private func scenarioCard(_ scenario: DemoScenario, index: Int) -> some View {
    Button {
      selectScenario(scenario)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        // Icon
        Image(systemName: scenario.icon)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 44, height: 44)
          .background(Circle().fill(.white.opacity(0.15)))

        // Title & description
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(scenario.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(scenario.description)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }

        // Ingredient chips
        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(scenario.ingredientNames.prefix(4), id: \.self) { name in
            Text(name)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.12), in: Capsule())
          }
          if scenario.ingredientNames.count > 4 {
            Text("+\(scenario.ingredientNames.count - 4)")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.6))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.08), in: Capsule())
          }
        }

        // Recipe hint
        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "fork.knife")
            .font(.system(size: 10, weight: .medium))
          Text(scenario.recipeHint)
            .font(AppTheme.Typography.labelSmall)
        }
        .foregroundStyle(.white.opacity(0.58))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .background(
        LinearGradient(
          colors: scenario.gradientColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(.white.opacity(0.05))
          .frame(width: 60, height: 60)
          .blur(radius: 15)
          .offset(x: 15, y: -10)
          .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .shadow(color: scenario.accentColor.opacity(0.15), radius: 8, x: 0, y: 4)
      .rotationEffect(.degrees(scenario.cardRotation), anchor: .center)
    }
    .buttonStyle(.plain)
    .disabled(loadingScenario != nil)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(
      reduceMotion
        ? nil : AppMotion.cardSpring.delay(Double(index) * AppMotion.staggerDelay + 0.08),
      value: appeared
    )
  }

  // MARK: - Own Photo Card

  private var ownPhotoCard: some View {
    Button {
      navigateToScan = true
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        Image(systemName: "camera.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .frame(width: 48, height: 48)
          .background(AppTheme.accentMuted, in: Circle())

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Use Your Own Photo")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Snap a photo of your real fridge or pantry.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(AppTheme.Space.md)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .strokeBorder(
            AppTheme.oat.opacity(0.40),
            style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(loadingScenario != nil)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.28),
      value: appeared
    )
  }

  // MARK: - Loading Overlay

  private func scenarioLoadingOverlay(_ scenario: DemoScenario) -> some View {
    ZStack {
      LinearGradient(
        colors: scenario.gradientColors + [
          scenario.gradientColors.last?.opacity(0.9) ?? scenario.accentColor
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        Image(systemName: scenario.icon)
          .font(.system(size: 48, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 96, height: 96)
          .background(Circle().fill(.white.opacity(0.12)))

        FLAnalyzingPulse()
          .frame(width: 36, height: 36)

        Text("Loading \(scenario.title)\u{2026}")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(.white)
      }
    }
    .accessibilityLabel("Loading \(scenario.title) scenario")
  }

  // MARK: - Actions

  private func selectScenario(_ scenario: DemoScenario) {
    guard loadingScenario == nil else { return }

    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      loadingScenario = scenario
    }

    Task {
      let payload = await DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )

      loadedDetections = payload.detections
      loadedProvenance = payload.provenance

      // Ensure minimum visible loading time for polish
      try? await Task.sleep(for: .milliseconds(1200))

      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        loadingScenario = nil
      }

      // Small delay for overlay dismiss animation
      try? await Task.sleep(for: .milliseconds(150))
      navigateToReview = true
    }
  }
}
