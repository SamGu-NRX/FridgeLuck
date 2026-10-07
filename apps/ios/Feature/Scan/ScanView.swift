import PhotosUI
import SwiftUI

/// Scan flow: capture → analyze → review.
struct ScanView: View {
  enum ScanMode {
    case live
    case demo
  }

  enum EntryMode {
    case standard
    case judgePath
  }

  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let mode: ScanMode
  let entryMode: EntryMode
  let demoScenario: DemoScenario?
  let scopedDependencies: Dependencies?

  struct Dependencies {
    let loadDemoPayload: (_ scenario: DemoScenario?) async -> DemoScanService.DemoScanPayload
    let scanInputs: (_ inputs: [ScanInput]) async throws -> VisionService.ScanResult
    let recordRun:
      (
        _ mode: ScanRunRecord.RunMode,
        _ inputSources: [ScanInputSource],
        _ provenance: ScanProvenance,
        _ diagnostics: ScanDiagnostics?,
        _ detections: [Detection]
      ) async -> Void
  }

  var dependencies: Dependencies {
    if let scopedDependencies { return scopedDependencies }
    return Dependencies(
      loadDemoPayload: { scenario in
        await DemoScanService.loadDemoPayload(scenario: scenario, using: deps.visionService)
      },
      scanInputs: { inputs in
        try await deps.visionService.scan(inputs: inputs)
      },
      recordRun: { mode, inputSources, provenance, diagnostics, detections in
        await deps.scanRunStore.record(
          mode: mode,
          inputSources: inputSources,
          provenance: provenance,
          diagnostics: diagnostics,
          detections: detections
        )
      }
    )
  }

  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var showRunReports = false
  @State private var isProcessing = false
  /// The running scan, cancelled when the screen goes away so Vision stops working on a result
  /// nobody will see.
  @State private var scanTask: Task<Void, Never>?
  @State private var detections: [Detection] = []
  @State private var capturedShots: [UIImage] = []
  @State private var capturedShotSources: [ScanInputSource] = []
  @State private var pendingCaptureSource: ScanInputSource = .camera
  private let maxShots = 3
  @State private var nutritionLabelOutcome: NutritionLabelParseOutcome?
  @State private var scanProvenance: ScanProvenance = .realScan
  @State private var scanDiagnostics: ScanDiagnostics?
  @State private var navigateToReview = false
  @State private var errorMessage: String?
  @State private var didStartDemoFlow = false
  @State private var fallbackStateText: String?
  @State private var cameraPermissionState: CameraPermissionState = .unknown

  init(
    mode: ScanMode = .live,
    entryMode: EntryMode = .standard,
    demoScenario: DemoScenario? = nil,
    dependencies: Dependencies? = nil
  ) {
    self.mode = mode
    self.entryMode = entryMode
    self.demoScenario = demoScenario
    self.scopedDependencies = dependencies
  }

  private enum ScanStage: Int {
    case capture = 1
    case analyze = 2
    case review = 3
  }

  private enum CameraPermissionState {
    case unknown
    case denied
    case unavailable
  }

  private var stage: ScanStage {
    if isProcessing { return .analyze }
    if navigateToReview || errorMessage != nil { return .review }
    return .capture
  }

  private var stageProgress: Double {
    Double(stage.rawValue) / 3.0
  }

  var body: some View {
    VStack(spacing: 0) {
      ScanArcStageIndicator(
        stageProgress: stageProgress,
        stageName: stageName,
        stageIndex: stage.rawValue,
        reduceMotion: reduceMotion
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.lg)

      ZStack {
        Group {
          if isProcessing {
            analyzingView
          } else if capturedImage != nil, errorMessage != nil {
            errorView
          } else {
            capturePromptView
          }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(reduceMotion ? nil : AppMotion.gentle, value: stage)
    }
    .padding(.horizontal, AppTheme.Space.page)
    .navigationTitle(mode == .demo ? "60-sec Demo" : "Scan Ingredients")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .fullScreenCover(isPresented: $showCamera) {
      FLCaptureView(
        configuration: FLCaptureConfiguration(
          title: "Scan Ingredients",
          subtitle: "Close framing improves matching",
          maxPhotos: 3,
          showManualEntry: true,
          manualEntryLabel: "Add Manually"
        ),
        capturedImages: $capturedShots,
        onDone: {
          finishCameraCapture()
        },
        onManualEntry: {
          beginManualEntry()
        }
      )
    }
    .photosPicker(
      isPresented: $showPhotoPicker,
      selection: $selectedPhotoItem,
      matching: .images
    )
    .sheet(isPresented: $showRunReports) {
      ScanRunReportSheet()
        .environmentObject(deps)
    }
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: detections,
        nutritionLabelOutcome: nutritionLabelOutcome,
        scanProvenance: scanProvenance,
        scanDiagnostics: scanDiagnostics,
        fridgeImage: capturedImage,
        savesToInventory: mode == .live
      )
    }
    .onAppear {
      beginDemoFlowIfNeeded()
      refreshCameraPermissionState()
    }
    // Scanning ends with navigation to the review, and the capture controls are hidden while it
    // runs, so the only disappearance during a scan is the user leaving.
    .onDisappear { scanTask?.cancel() }
    .onChange(of: selectedPhotoItem) { _, newValue in
      guard newValue != nil else { return }
      loadSelectedPhoto()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showRunReports = true
        } label: {
          Image(systemName: "doc.text.magnifyingglass")
        }
      }
    }
  }

  // MARK: - Arc Stage Indicator

  private var stageName: String {
    switch stage {
    case .capture: return "Capture"
    case .analyze: return "Analyzing"
    case .review: return "Review"
    }
  }

  // MARK: - Capture Stage

  private var capturePromptView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer(minLength: AppTheme.Space.md)

      if mode == .demo {
        ScanDemoCapturePreview(
          capturedImage: capturedImage,
          entryMode: entryMode,
          fallbackStateText: fallbackStateText,
          scanDiagnostics: scanDiagnostics
        )
      } else {
        ScanLiveCapturePrompt(
          capturedShotsCount: capturedShots.count,
          isCameraPermissionDenied: cameraPermissionState == .denied,
          isCameraUnavailable: cameraPermissionState == .unavailable,
          onOpenCamera: openCameraCapture,
          onOpenLibrary: openPhotoLibraryCapture,
          onOpenSettings: AppPermissionCenter.openAppSettings,
          onManualEntry: beginManualEntry
        )
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Analyze Stage

  private var analyzingView: some View {
    ScanAnalyzingView(
      capturedImage: capturedImage,
      fallbackStateText: fallbackStateText,
      reduceMotion: reduceMotion
    )
  }

  // MARK: - Error Stage

  private var errorView: some View {
    ScanErrorView(
      capturedImage: capturedImage,
      errorMessage: errorMessage,
      onManualEntry: beginManualEntry,
      onRetry: retryScan
    )
  }

  // MARK: - Flow Control

  private func beginManualEntry() {
    detections = []
    nutritionLabelOutcome = nil
    scanProvenance = .realScan
    scanDiagnostics = nil
    navigateToReview = true
  }

  private func openPhotoLibraryCapture() {
    pendingCaptureSource = .photoLibrary
    showPhotoPicker = true
  }

  private func retryScan() {
    errorMessage = nil
    if mode == .demo {
      didStartDemoFlow = false
      beginDemoFlowIfNeeded()
    } else {
      capturedImage = nil
      capturedShots.removeAll()
      capturedShotSources.removeAll()
    }
  }

  private func beginDemoFlowIfNeeded() {
    guard mode == .demo, !didStartDemoFlow else { return }
    didStartDemoFlow = true
    fallbackStateText = nil
    capturedShots.removeAll()
    capturedShotSources.removeAll()

    if capturedImage == nil {
      capturedImage = DemoScanService.loadDemoImage()
    }

    scanTask = Task {
      try? await Task.sleep(nanoseconds: 850_000_000)
      guard !Task.isCancelled else { return }
      await processImage()
    }
  }

  private func processImage() async {
    guard !isProcessing else { return }

    let startedAt = Date()
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      isProcessing = true
      errorMessage = nil
      fallbackStateText = nil
      scanDiagnostics = nil
    }

    defer {
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        isProcessing = false
      }
    }

    if mode == .demo {
      let payload = await dependencies.loadDemoPayload(demoScenario)
      detections = payload.detections
      nutritionLabelOutcome = nil
      scanProvenance = payload.provenance
      scanDiagnostics = payload.diagnostics
      if capturedImage == nil {
        capturedImage = payload.image
      }
      switch payload.provenance {
      case .realScan:
        fallbackStateText = nil
      case .bundledFixture:
        fallbackStateText = "Using bundled demo fixture for reliability."
      case .starterFallback:
        fallbackStateText =
          "Demo assets unavailable. Prefilled starter ingredients for reliable review."
      }
      await persistRunRecord(
        mode: .demo,
        detections: detections,
        provenance: payload.provenance,
        diagnostics: payload.diagnostics,
        inputSources: [.demo]
      )
    } else {
      guard let capturedImage else {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          errorMessage = "Pick or capture an image before scanning."
        }
        return
      }

      do {
        let imagesToScan: [UIImage] = {
          if !capturedShots.isEmpty {
            return Array(capturedShots.suffix(maxShots))
          }
          return [capturedImage]
        }()

        let inputs = imagesToScan.enumerated().compactMap { (index, image) -> ScanInput? in
          guard let cgImage = image.cgImage else { return nil }
          let source =
            capturedShotSources.indices.contains(index)
            ? capturedShotSources[index]
            : pendingCaptureSource
          return ScanInput(
            image: cgImage,
            source: source,
            captureIndex: index
          )
        }
        let result = try await dependencies.scanInputs(inputs)
        detections = result.detections
        nutritionLabelOutcome = NutritionLabelParser.parse(ocrText: result.ocrText)
        scanProvenance = result.provenance
        scanDiagnostics = result.diagnostics
        await persistRunRecord(
          mode: .live,
          detections: detections,
          provenance: result.provenance,
          diagnostics: result.diagnostics,
          inputSources: inputs.map(\.source)
        )
      } catch is CancellationError {
        return
      } catch {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          errorMessage = "Scan failed. Try better lighting or continue manually."
        }
        return
      }
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    let minAnalyzeDuration = reduceMotion ? 0.35 : 1.3
    if elapsed < minAnalyzeDuration {
      let remaining = minAnalyzeDuration - elapsed
      try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
    guard !Task.isCancelled else { return }

    if detections.isEmpty {
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        errorMessage =
          mode == .demo
          ? "Demo scan could not detect items. Continue with starter ingredients."
          : "No ingredients were found. Try a tighter crop or clearer lighting."
      }
      if mode == .demo {
        detections = [
          Detection(
            ingredientId: 1,
            label: IngredientLexicon.displayName(for: 1),
            confidence: 1.0,
            source: .manual,
            originalVisionLabel: "starter_egg",
            evidenceTokens: ["starter_fallback"],
            cropID: "starter",
            captureIndex: 0
          ),
          Detection(
            ingredientId: 2,
            label: IngredientLexicon.displayName(for: 2),
            confidence: 1.0,
            source: .manual,
            originalVisionLabel: "starter_rice",
            evidenceTokens: ["starter_fallback"],
            cropID: "starter",
            captureIndex: 0
          ),
        ]
        nutritionLabelOutcome = nil
        scanProvenance = .starterFallback
        fallbackStateText =
          "Demo scan found no items. Using starter fallback to keep the flow moving."
        await persistRunRecord(
          mode: .demo,
          detections: detections,
          provenance: .starterFallback,
          diagnostics: scanDiagnostics,
          inputSources: [.demo]
        )
        navigateToReview = true
      }
    } else {
      navigateToReview = true
    }
  }

  /// FLCaptureView appends and removes shots in `capturedShots` itself, so the camera path
  /// only re-aligns the source labels and starts the scan. Appending the last shot again here
  /// used to scan it twice and push the first photo out of the three-shot window.
  private func finishCameraCapture() {
    guard let lastShot = capturedShots.last else { return }
    // Sources only label run diagnostics. Shots added or removed inside the capture view are
    // counted as camera shots.
    if capturedShotSources.count > capturedShots.count {
      capturedShotSources.removeLast(capturedShotSources.count - capturedShots.count)
    }
    while capturedShotSources.count < capturedShots.count {
      capturedShotSources.append(.camera)
    }
    capturedImage = lastShot
    scanTask = Task { await processImage() }
  }

  private func addLibraryShot(_ image: UIImage) {
    capturedShots.append(image)
    capturedShotSources.append(.photoLibrary)
    if capturedShots.count > maxShots {
      capturedShots.removeFirst(capturedShots.count - maxShots)
    }
    if capturedShotSources.count > capturedShots.count {
      capturedShotSources.removeFirst(capturedShotSources.count - capturedShots.count)
    }
    capturedImage = image
    scanTask = Task { await processImage() }
  }

  private func openCameraCapture() {
    pendingCaptureSource = .camera
    Task {
      let result = await AppPermissionCenter.request(.camera)
      if AppPermissionCenter.canProceed(result) {
        cameraPermissionState = .unknown
        showCamera = true
        return
      }

      cameraPermissionState = mapCameraPermissionState(AppPermissionCenter.status(for: .camera))
      if cameraPermissionState == .unavailable {
        pendingCaptureSource = .photoLibrary
        showPhotoPicker = true
      }
    }
  }

  private func persistRunRecord(
    mode: ScanRunRecord.RunMode,
    detections: [Detection],
    provenance: ScanProvenance,
    diagnostics: ScanDiagnostics?,
    inputSources: [ScanInputSource]
  ) async {
    await dependencies.recordRun(mode, inputSources, provenance, diagnostics, detections)
  }

  private func refreshCameraPermissionState() {
    guard mode == .live else { return }
    cameraPermissionState = mapCameraPermissionState(AppPermissionCenter.status(for: .camera))
  }

  private func mapCameraPermissionState(_ status: AppPermissionStatus) -> CameraPermissionState {
    switch status {
    case .denied, .restricted:
      return .denied
    case .unavailable:
      return .unavailable
    case .authorized, .notDetermined, .limited:
      return .unknown
    }
  }

  private func loadSelectedPhoto() {
    guard let selectedPhotoItem else { return }

    Task {
      defer { self.selectedPhotoItem = nil }

      do {
        guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
          let image = UIImage(data: data)
        else { return }

        addLibraryShot(ScanImagePreprocessor.prepare(image))
      } catch {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          errorMessage = "Could not load the selected photo. Try another image."
        }
      }
    }
  }
}
