import SwiftUI

/// Unified demo hub — users pick a fridge scenario or use their own photo.
/// Replaces the old `DemoScenarioPicker` embedded in the tutorial home
/// with a dedicated, full-page experience.
struct DemoModeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - State

  @State private var appeared = false
  @State private var overlayPhase: OverlayPhase = .hidden
  @State private var activeScenario: DemoScenario?
  @State private var loadedDetections: [Detection] = []
  @State private var loadedProvenance: ScanProvenance = .bundledFixture
  @State private var navigateToReview = false
  @State private var navigateToScan = false
  @State private var demoImage: UIImage?
  @State private var discoveredCount: Int = 0
  @State private var scannerBracketsVisible = false
  @State private var scanComplete = false
  @State private var scanTask: Task<Void, Never>?

  // MARK: - Spotlight Tutorial State
  @AppStorage(TutorialStorageKeys.hasSeenDemoSpotlight) private var hasSeenDemoSpotlight = false
  @State private var demoSpotlight = SpotlightCoordinator()
  @State private var showDemoSpotlight = false
  @State private var isFirstVisit = false

  /// The overlay phases: preview first, then scanning.
  private enum OverlayPhase: Equatable {
    case hidden
    case preview(DemoScenario)
    case scanning(DemoScenario)
  }

  private var isOverlayVisible: Bool {
    overlayPhase != .hidden
  }

  private let columns = [
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
  ]

  // MARK: - Body

  var body: some View {
    ZStack {
      ScrollViewReader { scrollProxy in
        ScrollView {
          VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
            DemoModeHeaderSection(appeared: appeared)
              .padding(.horizontal, AppTheme.Space.page)

            DemoModeHowItWorksCallout(
              appeared: appeared,
              reduceMotion: reduceMotion,
              isFirstVisit: isFirstVisit
            )
            .padding(.horizontal, AppTheme.Space.page)

            scenarioGrid
              .padding(.horizontal, AppTheme.Space.page)
              .id("scenarioGrid")
              .spotlightAnchor("scenarioGrid")

            DemoOwnPhotoCard(
              isOverlayVisible: isOverlayVisible,
              appeared: appeared,
              reduceMotion: reduceMotion,
              onTap: { navigateToScan = true }
            )
            .padding(.horizontal, AppTheme.Space.page)
          }
          .padding(.top, AppTheme.Space.md)
          .padding(.bottom, AppTheme.Space.bottomClearance)
        }
        .onAppear {
          demoSpotlight.onScrollToAnchor = { anchorID in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              withAnimation(AppMotion.spotlightMove) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
              }
            }
          }
        }
      }

      if isOverlayVisible, let scenario = activeScenario {
        overlayContent(scenario)
          .transition(.opacity)
      }
    }
    .onPreferenceChange(SpotlightAnchorKey.self) { demoSpotlight.anchors = $0 }
    .overlay {
      if showDemoSpotlight, let steps = demoSpotlight.activeSteps {
        SpotlightTutorialOverlay(
          steps: steps,
          anchors: demoSpotlight.anchors,
          isPresented: Binding(
            get: { showDemoSpotlight },
            set: { isPresented in
              if !isPresented {
                showDemoSpotlight = false
                demoSpotlight.activeSteps = nil
              }
            }
          ),
          onScrollToAnchor: demoSpotlight.onScrollToAnchor
        )
        .ignoresSafeArea()
      }
    }
    .navigationTitle("Demo Mode")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .flPageBackground()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: handleBackButton) {
          Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOverlayVisible ? "Close preview" : "Back")
      }
    }
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: loadedDetections,
        scanProvenance: loadedProvenance,
        fridgeImage: demoImage
      )
    }
    .navigationDestination(isPresented: $navigateToScan) {
      ScanView(mode: .live)
    }
    .onAppear {
      if !hasSeenDemoSpotlight {
        isFirstVisit = true
      }
      guard !reduceMotion, !appeared else {
        appeared = true
        return
      }
      withAnimation(AppMotion.heroAppear.delay(0.1)) {
        appeared = true
      }
    }
    .task {
      guard !hasSeenDemoSpotlight else { return }
      let delay = reduceMotion ? 0.3 : 0.8
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard !showDemoSpotlight else { return }
      presentDemoSpotlight()
    }
  }

  // MARK: - Grid

  private var scenarioGrid: some View {
    LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
      ForEach(Array(DemoScenario.allCases.enumerated()), id: \.element.id) { index, scenario in
        DemoScenarioCard(
          scenario: scenario,
          index: index,
          isOverlayVisible: isOverlayVisible,
          appeared: appeared,
          reduceMotion: reduceMotion,
          onTap: { beginPreview(scenario) }
        )
      }
    }
  }

  // MARK: - Overlay Content (Preview -> Scanning)

  @ViewBuilder
  private func overlayContent(_ scenario: DemoScenario) -> some View {
    switch overlayPhase {
    case .preview:
      DemoScenarioPreviewOverlay(
        scenario: scenario,
        demoImage: demoImage,
        isFirstVisit: isFirstVisit,
        onScan: { beginScanning(scenario) }
      )
    case .scanning:
      DemoScenarioScanningOverlay(
        scenario: scenario,
        demoImage: demoImage,
        reduceMotion: reduceMotion,
        isFirstVisit: isFirstVisit,
        discoveredCount: discoveredCount,
        scanComplete: scanComplete,
        scannerBracketsVisible: $scannerBracketsVisible
      )
    case .hidden:
      EmptyView()
    }
  }

  // MARK: - Spotlight

  private func presentDemoSpotlight() {
    guard demoSpotlight.activeSteps == nil else { return }
    demoSpotlight.activeSteps = SpotlightStep.demoMode
    showDemoSpotlight = true
    hasSeenDemoSpotlight = true
  }

  // MARK: - Actions

  /// Phase 1: Show the fridge preview with scenario info.
  private func beginPreview(_ scenario: DemoScenario) {
    guard !isOverlayVisible else { return }
    scanTask?.cancel()
    scanTask = nil

    demoImage = DemoScanService.loadScenarioImage(for: scenario)
    activeScenario = scenario
    discoveredCount = 0
    scanComplete = false
    scannerBracketsVisible = false

    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .preview(scenario)
    }
  }

  /// Phase 2: Transition from preview to scanning with the slower animation.
  private func beginScanning(_ scenario: DemoScenario) {
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .scanning(scenario)
    }

    scanTask?.cancel()
    scanTask = Task {
      async let payloadFetch = DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )

      let totalIngredients = scenario.ingredientNames.count
      for i in 1...totalIngredients {
        do {
          try await Task.sleep(for: .milliseconds(Int.random(in: 300...500)))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          discoveredCount = i
        }
      }

      let payload = await payloadFetch
      guard !Task.isCancelled else { return }

      loadedDetections = payload.detections
      loadedProvenance = payload.provenance

      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        scanComplete = true
      }
      do {
        try await Task.sleep(for: .milliseconds(800))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }

      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        overlayPhase = .hidden
        activeScenario = nil
      }

      do {
        try await Task.sleep(for: .milliseconds(180))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      navigateToReview = true
      scanTask = nil
    }
  }

  private func handleBackButton() {
    if isOverlayVisible {
      closeOverlay()
      return
    }
    dismiss()
  }

  private func closeOverlay() {
    scanTask?.cancel()
    scanTask = nil
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .hidden
      activeScenario = nil
    }
    discoveredCount = 0
    scanComplete = false
    scannerBracketsVisible = false
  }
}
