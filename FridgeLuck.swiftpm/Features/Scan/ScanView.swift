import AVFoundation
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

  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoLibrary = false
  @State private var isProcessing = false
  @State private var detections: [Detection] = []
  @State private var nutritionLabelOutcome: NutritionLabelParseOutcome?
  @State private var navigateToReview = false
  @State private var errorMessage: String?
  @State private var didStartDemoFlow = false
  @State private var fallbackStateText: String?
  @State private var cameraPermissionState: CameraPermissionState = .unknown

  init(mode: ScanMode = .live, entryMode: EntryMode = .standard, demoScenario: DemoScenario? = nil)
  {
    self.mode = mode
    self.entryMode = entryMode
    self.demoScenario = demoScenario
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
      arcStageIndicator
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
    .sheet(isPresented: $showCamera) {
      CameraPicker(image: $capturedImage)
        .ignoresSafeArea()
    }
    .sheet(isPresented: $showPhotoLibrary) {
      PhotoLibraryPicker(image: $capturedImage)
        .ignoresSafeArea()
    }
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: detections,
        nutritionLabelOutcome: nutritionLabelOutcome
      )
    }
    .onAppear {
      beginDemoFlowIfNeeded()
      refreshCameraPermissionState()
    }
    .onChange(of: capturedImage) { _, newValue in
      guard mode == .live, newValue != nil else { return }
      Task { await processImage() }
    }
  }

  // MARK: - Arc Stage Indicator

  private var arcStageIndicator: some View {
    HStack(spacing: AppTheme.Space.lg) {
      FLArcIndicator(
        progress: stageProgress,
        steps: 3,
        size: 56
      )
      .frame(width: 72, height: 56, alignment: .center)
      .padding(.leading, AppTheme.Space.xs)
      .animation(reduceMotion ? nil : AppMotion.gentle, value: stageProgress)

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(stageName)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Step \(stage.rawValue) of 3")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
  }

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
        demoCapturePreview
      } else {
        liveCapturePrompt
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var liveCapturePrompt: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 72, weight: .thin))
        .foregroundStyle(AppTheme.accent.opacity(0.7))
        .padding(AppTheme.Space.xl)
        .background(
          Circle()
            .fill(AppTheme.accent.opacity(0.06))
            .frame(width: 160, height: 160)
        )

      VStack(spacing: AppTheme.Space.sm) {
        Text("Photograph your ingredients")
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text("Close framing improves ingredient matching and recipe quality.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLPrimaryButton("Open Camera", systemImage: "camera.fill") {
          openCameraCapture()
        }

        FLSecondaryButton("Choose from Library", systemImage: "photo.on.rectangle") {
          showPhotoLibrary = true
        }

        Button {
          detections = []
          nutritionLabelOutcome = nil
          navigateToReview = true
        } label: {
          Label("Add Ingredients Manually", systemImage: "plus.circle")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, AppTheme.Space.xs)
      }

      if cameraPermissionState == .denied {
        FLCard(tone: .warning) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Camera permission is off")
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Use photo library or manual ingredients to finish without camera access.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: AppTheme.Space.sm) {
              FLSecondaryButton("Use Library", systemImage: "photo.on.rectangle") {
                showPhotoLibrary = true
              }
              FLSecondaryButton("Manual", systemImage: "plus.circle") {
                detections = []
                nutritionLabelOutcome = nil
                navigateToReview = true
              }
            }
          }
        }
      }

      if cameraPermissionState == .unavailable {
        Text("Camera unavailable on this device. Library and manual entry are ready.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
  }

  private var demoCapturePreview: some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        Group {
          if let capturedImage {
            Image(uiImage: capturedImage)
              .resizable()
              .scaledToFill()
          } else {
            LinearGradient(
              colors: [AppTheme.deepOliveLight, AppTheme.deepOlive],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          LinearGradient(
            colors: [Color.black.opacity(0.04), Color.black.opacity(0.20)],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      }
      .frame(height: 260)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.32), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 10, x: 0, y: 3)

      VStack(spacing: AppTheme.Space.xs) {
        Text("Demo frame loaded")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Text(
          entryMode == .judgePath
            ? "Judge flow: demo photo, review, and best recipe."
            : "Running the same scan path: capture, analyze, then review."
        )
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)

        if let fallbackStateText {
          Text(fallbackStateText)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
            .multilineTextAlignment(.center)
            .padding(.top, AppTheme.Space.xxs)
        }
      }
    }
  }

  // MARK: - Analyze Stage

  private var analyzingView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ZStack {
        analyzingBackgroundImage
        ScanSweepOverlay(isAnimating: !reduceMotion)
      }
      .frame(height: 300)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
      )

      VStack(spacing: AppTheme.Space.sm) {
        Text("Scanning your fridge")
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
        Text("Finding ingredients and preparing your luck-based recipe set.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(3)
          .multilineTextAlignment(.center)
        if let fallbackStateText {
          Text(fallbackStateText)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, AppTheme.Space.md)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var analyzingBackgroundImage: some View {
    if let capturedImage {
      Image(uiImage: capturedImage)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          Color.black.opacity(0.24)
        }
    } else {
      LinearGradient(
        colors: [AppTheme.deepOliveLight, AppTheme.deepOlive],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .overlay {
        Image(systemName: "camera.macro")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(AppTheme.surface.opacity(0.75))
      }
    }
  }

  // MARK: - Error Stage

  private var errorView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      if let capturedImage {
        Image(uiImage: capturedImage)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 190)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
      }

      VStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.accent)

        Text("Scan needs another pass")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        if let errorMessage {
          Text(errorMessage)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        Text("You can retry, or continue by manually picking ingredients.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLPrimaryButton("Add Ingredients Manually", systemImage: "plus.circle.fill") {
          detections = []
          nutritionLabelOutcome = nil
          navigateToReview = true
        }

        FLSecondaryButton("Retry Scan", systemImage: "arrow.clockwise") {
          errorMessage = nil
          if mode == .demo {
            didStartDemoFlow = false
            beginDemoFlowIfNeeded()
          } else {
            capturedImage = nil
          }
        }
      }
    }
  }

  // MARK: - Flow Control

  private func beginDemoFlowIfNeeded() {
    guard mode == .demo, !didStartDemoFlow else { return }
    didStartDemoFlow = true
    fallbackStateText = nil

    if capturedImage == nil {
      capturedImage = DemoScanService.loadDemoImage()
    }

    Task {
      try? await Task.sleep(nanoseconds: 850_000_000)
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
    }

    defer {
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        isProcessing = false
      }
    }

    if mode == .demo {
      let payload = await DemoScanService.loadDemoPayload(
        scenario: demoScenario, using: deps.visionService)
      detections = payload.detections
      nutritionLabelOutcome = nil
      if capturedImage == nil {
        capturedImage = payload.image
      }
      if payload.usedStarterFallback {
        fallbackStateText =
          "Demo assets unavailable. Prefilled starter ingredients for reliable review."
      } else if payload.usedBundledFixture {
        fallbackStateText = "Using bundled demo fixture for reliability."
      }
    } else {
      guard let capturedImage, let cgImage = capturedImage.cgImage else {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          errorMessage = "Pick or capture an image before scanning."
        }
        return
      }

      do {
        let result = try await deps.visionService.scan(image: cgImage)
        detections = result.detections
        nutritionLabelOutcome = NutritionLabelParser.parse(ocrText: result.ocrText)
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
            originalVisionLabel: "starter_egg"
          ),
          Detection(
            ingredientId: 2,
            label: IngredientLexicon.displayName(for: 2),
            confidence: 1.0,
            source: .manual,
            originalVisionLabel: "starter_rice"
          ),
        ]
        nutritionLabelOutcome = nil
        navigateToReview = true
      }
    } else {
      navigateToReview = true
    }
  }

  private func openCameraCapture() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      cameraPermissionState = .unavailable
      showPhotoLibrary = true
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      cameraPermissionState = .unknown
      showCamera = true
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.cameraPermissionState = .unknown
            self.showCamera = true
          } else {
            self.cameraPermissionState = .denied
          }
        }
      }
    case .denied, .restricted:
      cameraPermissionState = .denied
    @unknown default:
      cameraPermissionState = .unavailable
      showPhotoLibrary = true
    }
  }

  private func refreshCameraPermissionState() {
    guard mode == .live else { return }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      cameraPermissionState = .unavailable
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized, .notDetermined:
      cameraPermissionState = .unknown
    case .denied, .restricted:
      cameraPermissionState = .denied
    @unknown default:
      cameraPermissionState = .unavailable
    }
  }
}

private struct ScanSweepOverlay: View {
  let isAnimating: Bool

  @State private var travel: CGFloat = 0.08

  var body: some View {
    GeometryReader { geo in
      let y = max(12, min(geo.size.height - 12, geo.size.height * travel))
      ZStack {
        LinearGradient(
          colors: [Color.clear, Color.white.opacity(0.08), Color.clear],
          startPoint: .top,
          endPoint: .bottom
        )

        Rectangle()
          .fill(
            LinearGradient(
              colors: [
                AppTheme.accent.opacity(0.12), AppTheme.surface.opacity(0.90),
                AppTheme.accent.opacity(0.12),
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(height: 2)
          .position(x: geo.size.width / 2, y: y)
          .shadow(color: AppTheme.accent.opacity(0.45), radius: 8, x: 0, y: 0)

        LinearGradient(
          colors: [
            AppTheme.accent.opacity(0.00), AppTheme.accent.opacity(0.22),
            AppTheme.accent.opacity(0.00),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 74)
        .position(x: geo.size.width / 2, y: y)
        .blur(radius: 6)
      }
      .onAppear {
        startSweepIfNeeded()
      }
      .onChange(of: isAnimating) { _, _ in
        startSweepIfNeeded()
      }
    }
  }

  private func startSweepIfNeeded() {
    if isAnimating {
      travel = 0.08
      withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: true)) {
        travel = 0.92
      }
    } else {
      travel = 0.5
    }
  }
}
