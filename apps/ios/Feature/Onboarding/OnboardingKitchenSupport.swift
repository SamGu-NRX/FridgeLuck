import PhotosUI
import SwiftUI
import UIKit

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
  /// Names one photo for VoiceOver, as in "Remove fridge photo 2".
  let photoName: String
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
    maxPhotos: 3,
    photoName: "fridge photo"
  )

  static let pantry = OnboardingKitchenCaptureConfiguration(
    heroFill: AppTheme.oat.opacity(0.18),
    heroIcon: "cabinet.fill",
    heroIconTint: AppTheme.accent,
    title: "Photograph your pantry",
    subtitle: "Dry goods, cans, oils, spices — anything on the shelves.",
    cameraTitle: "Photograph Your Pantry",
    cameraSubtitle: "Dry goods, cans, oils, spices",
    maxPhotos: 3,
    photoName: "pantry photo"
  )
}

struct OnboardingKitchenCaptureStep: View {
  private struct ThumbnailItem: Identifiable {
    let id: UUID
    let index: Int
    let image: UIImage
  }

  let configuration: OnboardingKitchenCaptureConfiguration
  @Binding var photos: [FLCapturedPhoto]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var showCamera = false
  @State private var selectedPhotoItem: PhotosPickerItem?

  private var thumbnailItems: [ThumbnailItem] {
    Array(photos.prefix(configuration.maxPhotos)).enumerated().map { index, photo in
      ThumbnailItem(id: photo.id, index: index, image: photo.image)
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
            .accessibilityHidden(true)
        }
        .inventoryStagger(index: 0, appeared: appeared)

        VStack(spacing: AppTheme.Space.xs) {
          Text(configuration.title)
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
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
                    .accessibilityLabel(
                      "\(configuration.photoName) \(item.index + 1) of \(configuration.maxPhotos)")

                  Button {
                    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
                      if item.index < photos.count {
                        photos.remove(at: item.index)
                      }
                    }
                  } label: {
                    // A 44 pt target kept inside the thumbnail, so neighbouring targets can't
                    // overlap and the scroll view can't clip it.
                    Image(systemName: "xmark.circle.fill")
                      .font(.system(size: 18))
                      .foregroundStyle(.white)
                      .background(Circle().fill(AppTheme.textPrimary.opacity(0.6)))
                      .padding(AppTheme.Space.xxs)
                      .frame(width: 44, height: 44, alignment: .topTrailing)
                      .contentShape(Rectangle())
                  }
                  .accessibilityLabel("Remove \(configuration.photoName) \(item.index + 1)")
                }
              }
            }
            .padding(.horizontal, AppTheme.Space.xs)
          }
          .transition(.opacity.combined(with: .scale(scale: 0.95)))

          Text("\(photos.count) of \(configuration.maxPhotos) photos")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.sage)
            .accessibilityLiveRegion(.polite)
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
        photos: $photos,
        onDone: {}
      )
    }
    .onChange(of: selectedPhotoItem) { _, newItem in
      guard let newItem else { return }
      Task {
        if let data = try? await newItem.loadTransferable(type: Data.self),
          let image = UIImage(data: data),
          photos.count < configuration.maxPhotos
        {
          withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
            photos.append(
              FLCapturedPhoto(
                image: ScanImagePreprocessor.prepare(image),
                source: .photoLibrary
              )
            )
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
