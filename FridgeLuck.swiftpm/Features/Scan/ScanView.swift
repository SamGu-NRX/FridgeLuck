import SwiftUI

/// Scan flow: take a photo → run Vision pipeline → navigate to ingredient review.
struct ScanView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoLibrary = false
  @State private var isProcessing = false
  @State private var detections: [Detection] = []
  @State private var nutritionLabelOutcome: NutritionLabelParseOutcome?
  @State private var navigateToReview = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 24) {
      if isProcessing {
        processingView
      } else if capturedImage != nil, errorMessage != nil {
        errorView
      } else {
        promptView
      }
    }
    .navigationTitle("Scan Ingredients")
    .navigationBarTitleDisplayMode(.inline)
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

  // MARK: - Prompt View

  private var promptView: some View {
    VStack(spacing: 20) {
      Spacer()

      Image(systemName: "camera.viewfinder")
        .font(.system(size: 80))
        .foregroundStyle(.yellow)

      Text("Take a photo of your ingredients")
        .font(.title3.bold())

      Text("For best results, take close-up photos\nof a few ingredients at a time.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()

      VStack(spacing: 12) {
        Button {
          showCamera = true
        } label: {
          Label("Open Camera", systemImage: "camera.fill")
            .frame(maxWidth: .infinity)
            .padding()
            .background(.yellow)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .font(.headline)
        }

        Button {
          showPhotoLibrary = true
        } label: {
          Label("Choose from Library", systemImage: "photo.on.rectangle")
            .frame(maxWidth: .infinity)
            .padding()
            .background(.gray.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .font(.headline)
        }
      }
      .padding(.bottom, 32)
    }
    .padding(.horizontal)
  }

  // MARK: - Processing View

  private var processingView: some View {
    VStack(spacing: 20) {
      Spacer()
      ProgressView()
        .controlSize(.large)
      Text("Analyzing your ingredients...")
        .font(.headline)
      Text("Running Vision AI")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
    }
  }

  // MARK: - Error / Empty Results View

  private var errorView: some View {
    VStack(spacing: 16) {
      Spacer()

      if let image = capturedImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal)
      }

      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(.orange)

      Text(errorMessage ?? "Something went wrong")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Spacer()

      VStack(spacing: 12) {
        // Allow user to add ingredients manually even if Vision failed
        Button {
          detections = []
          nutritionLabelOutcome = nil
          navigateToReview = true
        } label: {
          Label("Add Ingredients Manually", systemImage: "plus.circle.fill")
            .frame(maxWidth: .infinity)
            .padding()
            .background(.yellow)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .font(.headline)
        }

        Button {
          capturedImage = nil
          errorMessage = nil
        } label: {
          Text("Try Again")
            .frame(maxWidth: .infinity)
            .padding()
            .background(.gray.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .font(.headline)
        }
      }
      .padding(.bottom, 32)
    }
    .padding(.horizontal)
  }

  // MARK: - Processing

  private func processImage() async {
    guard let uiImage = capturedImage,
      let cgImage = uiImage.cgImage
    else { return }

    isProcessing = true
    errorMessage = nil

    do {
      let result = try await deps.visionService.scan(image: cgImage)
      detections = result.detections
      nutritionLabelOutcome = NutritionLabelParser.parse(ocrText: result.ocrText)
      isProcessing = false

      if detections.isEmpty {
        errorMessage = "No ingredients detected. Try a closer photo, or add manually."
      } else {
        navigateToReview = true
      }
    } catch {
      isProcessing = false
      errorMessage = "Vision scan failed. You can add ingredients manually instead."
    }
  }
}
