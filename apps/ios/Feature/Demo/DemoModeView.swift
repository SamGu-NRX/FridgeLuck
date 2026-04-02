import SwiftUI

/// Unified demo hub — users pick a fridge scenario or use their own photo.
/// Replaces the old `DemoScenarioPicker` embedded in the tutorial home
/// with a dedicated, full-page experience.
struct DemoModeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - State

  @State private var replaySpotlightPending: Bool
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

  // MARK: - Tutorial Integration
  @Environment(TutorialFlowContext.self) private var tutorialFlowContext: TutorialFlowContext?
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

  private var shouldAutoPresentDemoSpotlight: Bool {
    guard !hasSeenDemoSpotlight else { return false }
    guard appeared else { return false }
    guard demoSpotlight.activePresentation == nil else { return false }
    guard !showDemoSpotlight else { return false }
    return true
  }

  private var pendingSpotlightTrigger: Bool {
    replaySpotlightPending || shouldAutoPresentDemoSpotlight
  }

  init(replaySpotlightOnAppear: Bool = false) {
    _replaySpotlightPending = State(initialValue: replaySpotlightOnAppear)
  }

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
    .onPreferenceChange(SpotlightAnchorKey.self) {
      demoSpotlight.updateAnchors($0)
    }
    .overlay {
      if showDemoSpotlight, let presentation = demoSpotlight.activePresentation {
        SpotlightTutorialOverlay(
          presentationID: presentation.id,
          steps: presentation.steps,
          anchors: demoSpotlight.anchors,
          isPresented: Binding(
            get: { showDemoSpotlight },
            set: { isPresented in
              if !isPresented {
                showDemoSpotlight = false
                demoSpotlight.activePresentation = nil
              }
            }
          ),
          onScrollToAnchor: demoSpotlight.onScrollToAnchor
        )
        .id(presentation.id)
        .ignoresSafeArea()
      }
    }
    .navigationTitle("Demo Mode")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(isOverlayVisible || showDemoSpotlight)
    .flPageBackground()
    .toolbar {
      if isOverlayVisible {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: closeOverlay) {
            Label("Close", systemImage: "xmark")
              .labelStyle(.iconOnly)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)
              .frame(width: 32, height: 32)
              .background(
                AppTheme.surfaceMuted,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close preview")
        }
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
    .task(id: pendingSpotlightTrigger) {
      guard pendingSpotlightTrigger else { return }
      let delay = reduceMotion ? 0.3 : 0.8
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard pendingSpotlightTrigger else { return }
      presentDemoSpotlight(markSeen: !replaySpotlightPending)
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

  private func presentDemoSpotlight(markSeen: Bool) {
    guard demoSpotlight.activePresentation == nil else { return }
    demoSpotlight.present(steps: SpotlightStep.demoMode, source: "demoMode")
    showDemoSpotlight = true
    replaySpotlightPending = false
    if markSeen {
      hasSeenDemoSpotlight = true
    }
  }

  // MARK: - Actions

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

      if tutorialFlowContext?.activeQuest == .firstScan {
        tutorialFlowContext?.completeObjective()
        scanTask = nil
        return
      }

      navigateToReview = true
      scanTask = nil
    }
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
