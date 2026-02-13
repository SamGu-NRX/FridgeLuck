import SwiftUI

/// Scan flow: take a photo → run Vision pipeline → navigate to ingredient review.
struct ScanView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoLibrary = false
  @State private var isProcessing = false
  @State private var detections: [Detection] = []
  @State private var nutritionLabelOutcome: NutritionLabelParseOutcome?
  @State private var navigateToReview = false
  @State private var errorMessage: String?

  private enum ScanStage: Int {
    case capture = 1
    case analyze = 2
    case review = 3
  }

  private var stage: ScanStage {
    if isProcessing { return .analyze }
    if errorMessage != nil { return .review }
    return .capture
  }

  private var stageProgress: Double {
    Double(stage.rawValue) / 3.0
  }

  var body: some View {
    VStack(spacing: AppTheme.Space.md) {
      stageIndicator
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
      .animation(reduceMotion ? nil : AppMotion.gentle, value: stage)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.top, AppTheme.Space.md)
    .navigationTitle("Scan Ingredients")
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
    .onChange(of: capturedImage) { _, newValue in
      if newValue != nil {
        Task { await processImage() }
      }
    }
  }

  private var stageIndicator: some View {
    FLCard(tone: .warm) {
      HStack(spacing: AppTheme.Space.sm) {
        stageDot(.capture, title: "Capture")
        stageConnector(active: stage.rawValue > ScanStage.capture.rawValue)
        stageDot(.analyze, title: "Analyze")
        stageConnector(active: stage.rawValue > ScanStage.analyze.rawValue)
        stageDot(.review, title: "Review")
      }
      .overlay(alignment: .bottomLeading) {
        GeometryReader { geo in
          Capsule()
            .fill(AppTheme.accent.opacity(0.22))
            .frame(width: geo.size.width * stageProgress, height: 3)
            .offset(y: 12)
        }
      }
    }
  }

  @ViewBuilder
  private func stageDot(_ dotStage: ScanStage, title: String) -> some View {
    let active = stage.rawValue >= dotStage.rawValue
    VStack(spacing: AppTheme.Space.xs) {
      Circle()
        .fill(active ? AppTheme.accent : AppTheme.neutral.opacity(0.3))
        .frame(width: active ? 12 : 10, height: active ? 12 : 10)
        .animation(reduceMotion ? nil : AppMotion.quick, value: active)
      Text(title)
        .font(.caption2)
        .foregroundStyle(active ? AppTheme.textPrimary : AppTheme.textSecondary)
    }
  }

  private func stageConnector(active: Bool) -> some View {
    Rectangle()
      .fill(active ? AppTheme.accent.opacity(0.5) : AppTheme.neutral.opacity(0.25))
      .frame(height: 1)
      .frame(maxWidth: .infinity)
      .padding(.top, -10)
  }

  private var capturePromptView: some View {
    VStack(spacing: AppTheme.Space.md) {
      FLCard(tone: .warm) {
        VStack(spacing: AppTheme.Space.md) {
          Image(systemName: "camera.viewfinder")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(AppTheme.accent)

          Text("Take close-up photos of a few ingredients at a time")
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Close framing improves confidence and reduces manual corrections.")
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }

      FLPrimaryButton("Open Camera", systemImage: "camera.fill") {
        showCamera = true
      }

      FLSecondaryButton("Choose from Library", systemImage: "photo.on.rectangle") {
        showPhotoLibrary = true
      }

      FLSecondaryButton(
        "Add Ingredients Manually", systemImage: "plus.circle", isEnabled: !isProcessing
      ) {
        detections = []
        nutritionLabelOutcome = nil
        navigateToReview = true
      }
    }
  }

  private var analyzingView: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        ProgressView()
          .controlSize(.large)
        Text("Analyzing your ingredients")
          .font(.headline)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Running image classification and OCR locally.")
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.xl)
    }
  }

  private var errorView: some View {
    VStack(spacing: AppTheme.Space.md) {
      FLCard(tone: .warning) {
        VStack(spacing: AppTheme.Space.md) {
          if let image = capturedImage {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 190)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
          }

          FLSectionHeader(
            "Couldn’t build a confident ingredient set", subtitle: errorMessage,
            icon: "exclamationmark.triangle.fill")

          Text("You can retry capture or continue by manually selecting ingredients.")
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }

      FLPrimaryButton("Add Ingredients Manually", systemImage: "plus.circle.fill") {
        detections = []
        nutritionLabelOutcome = nil
        navigateToReview = true
      }

      FLSecondaryButton("Retry Capture", systemImage: "arrow.clockwise") {
        capturedImage = nil
        errorMessage = nil
      }
    }
  }

  private func processImage() async {
    guard let uiImage = capturedImage, let cgImage = uiImage.cgImage else { return }

    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      isProcessing = true
      errorMessage = nil
    }

    do {
      let result = try await deps.visionService.scan(image: cgImage)
      detections = result.detections
      nutritionLabelOutcome = NutritionLabelParser.parse(ocrText: result.ocrText)
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        isProcessing = false
      }

      if detections.isEmpty {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          errorMessage = "No ingredients detected. Try a tighter crop or better lighting."
        }
      } else {
        navigateToReview = true
      }
    } catch {
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        isProcessing = false
        errorMessage = "Vision scan failed. Continue manually if needed."
      }
    }
  }
}
