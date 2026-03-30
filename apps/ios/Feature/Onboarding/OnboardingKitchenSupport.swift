import PhotosUI
import SwiftUI
import UIKit

enum OnboardingKitchenDemoDetections {
  struct KitchenDetectionSet {
    let fridgeItems: [Detection]
    let pantryItems: [Detection]
  }

  static func load() -> KitchenDetectionSet {
    KitchenDetectionSet(
      fridgeItems: detections(
        items: [
          (1, 0.94),
          (3, 0.91),
          (15, 0.87),
          (8, 0.82),
          (7, 0.88),
          (14, 0.78),
          (10, 0.85),
          (9, 0.73),
        ],
        labelPrefix: "onboarding_fridge",
        cropID: "kitchen_fridge"
      ),
      pantryItems: detections(
        items: [
          (2, 0.95),
          (4, 0.89),
          (5, 0.92),
          (11, 0.86),
          (6, 0.90),
          (12, 0.83),
        ],
        labelPrefix: "onboarding_pantry",
        cropID: "kitchen_pantry"
      )
    )
  }

  private static func detections(
    items: [(id: Int64, confidence: Float)],
    labelPrefix: String,
    cropID: String
  ) -> [Detection] {
    items.map { item in
      Detection(
        ingredientId: item.id,
        label: IngredientLexicon.displayName(for: item.id),
        confidence: item.confidence,
        source: .vision,
        originalVisionLabel: "\(labelPrefix)_\(item.id)",
        alternatives: [],
        normalizedBoundingBox: nil,
        evidenceTokens: ["onboarding_kitchen_capture"],
        cropID: cropID,
        captureIndex: 0,
        ocrMatchKind: nil
      )
    }
  }
}

private struct InventoryStepStaggerIn: ViewModifier {
  let index: Int
  let appeared: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(reduceMotion || appeared ? 1 : 0)
      .offset(y: reduceMotion || appeared ? 0 : 14)
      .animation(
        reduceMotion
          ? nil
          : AppMotion.staggerEntrance.delay(Double(index) * AppMotion.staggerInterval),
        value: appeared
      )
  }
}

extension View {
  func inventoryStagger(index: Int, appeared: Bool) -> some View {
    modifier(InventoryStepStaggerIn(index: index, appeared: appeared))
  }
}

struct OnboardingKitchenCaptureConfiguration {
  let heroFill: Color
  let heroIcon: String
  let heroIconTint: Color
  let title: String
  let subtitle: String
  let cameraTitle: String
  let cameraSubtitle: String
  let maxPhotos: Int
}

extension OnboardingKitchenCaptureConfiguration {
  static let fridge = OnboardingKitchenCaptureConfiguration(
    heroFill: AppTheme.accent.opacity(0.10),
    heroIcon: "camera.fill",
    heroIconTint: AppTheme.accent,
    title: "Photograph your fridge",
    subtitle: "Multiple close-ups work better than one wide shot.",
    cameraTitle: "Photograph Your Fridge",
    cameraSubtitle: "Multiple close-ups work best",
    maxPhotos: 3
  )

  static let pantry = OnboardingKitchenCaptureConfiguration(
    heroFill: AppTheme.oat.opacity(0.18),
    heroIcon: "cabinet.fill",
    heroIconTint: AppTheme.accent,
    title: "Photograph your pantry",
    subtitle: "Dry goods, cans, oils, spices — anything on the shelves.",
    cameraTitle: "Photograph Your Pantry",
    cameraSubtitle: "Dry goods, cans, oils, spices",
    maxPhotos: 3
  )
}

struct OnboardingKitchenCaptureStep: View {
  private struct ThumbnailItem: Identifiable {
    let id: ObjectIdentifier
    let index: Int
    let image: UIImage
  }

  let configuration: OnboardingKitchenCaptureConfiguration
  @Binding var capturedImages: [UIImage]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var showCamera = false
  @State private var selectedPhotoItem: PhotosPickerItem?

  private var thumbnailItems: [ThumbnailItem] {
    Array(capturedImages.prefix(configuration.maxPhotos)).enumerated().map { index, image in
      ThumbnailItem(id: ObjectIdentifier(image), index: index, image: image)
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.lg) {
        Spacer(minLength: AppTheme.Space.md)

        ZStack {
          Circle()
            .fill(configuration.heroFill)
            .frame(width: 80, height: 80)

          Image(systemName: configuration.heroIcon)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(configuration.heroIconTint)
        }
        .inventoryStagger(index: 0, appeared: appeared)

        VStack(spacing: AppTheme.Space.xs) {
          Text(configuration.title)
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .inventoryStagger(index: 1, appeared: appeared)

          Text(configuration.subtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .inventoryStagger(index: 2, appeared: appeared)
        }

        HStack(spacing: AppTheme.Space.md) {
          Button {
            showCamera = true
          } label: {
            Label("Camera", systemImage: "camera")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.accent)
              .frame(maxWidth: .infinity)
              .padding(.vertical, AppTheme.Space.buttonVertical)
              .background(
                AppTheme.accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              )
              .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                  .stroke(AppTheme.accent.opacity(0.20), lineWidth: 1)
              )
          }
          .buttonStyle(FLPressableButtonStyle())

          PhotosPicker(
            selection: $selectedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
          ) {
            Label("Library", systemImage: "photo.on.rectangle")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, AppTheme.Space.buttonVertical)
              .background(
                AppTheme.surfaceMuted,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              )
              .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                  .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
              )
          }
        }
        .inventoryStagger(index: 3, appeared: appeared)

        if !thumbnailItems.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Space.sm) {
              ForEach(thumbnailItems) { item in
                ZStack(alignment: .topTrailing) {
                  Image(uiImage: item.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(
                      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .stroke(AppTheme.sage.opacity(0.30), lineWidth: 1)
                    )

                  Button {
                    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
                      if item.index < capturedImages.count {
                        capturedImages.remove(at: item.index)
                      }
                    }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .font(.system(size: 18))
                      .foregroundStyle(.white)
                      .background(Circle().fill(AppTheme.textPrimary.opacity(0.6)))
                  }
                  .offset(x: 6, y: -6)
                }
              }
            }
            .padding(.horizontal, AppTheme.Space.xs)
          }
          .transition(.opacity.combined(with: .scale(scale: 0.95)))

          Text("\(capturedImages.count) of \(configuration.maxPhotos) photos")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.sage)
        }

        Text("You can skip this step and add items later from the scan orb.")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .inventoryStagger(index: 4, appeared: appeared)

        Spacer(minLength: AppTheme.Space.xl)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .fullScreenCover(isPresented: $showCamera) {
      FLCaptureView(
        configuration: FLCaptureConfiguration(
          title: configuration.cameraTitle,
          subtitle: configuration.cameraSubtitle,
          maxPhotos: configuration.maxPhotos
        ),
        capturedImages: $capturedImages,
        onDone: {}
      )
    }
    .onChange(of: selectedPhotoItem) { _, newItem in
      guard let newItem else { return }
      Task {
        if let data = try? await newItem.loadTransferable(type: Data.self),
          let image = UIImage(data: data),
          capturedImages.count < configuration.maxPhotos
        {
          withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
            capturedImages.append(image)
          }
        }
        selectedPhotoItem = nil
      }
    }
    .task {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) {
          appeared = true
        }
      }
    }
  }
}
