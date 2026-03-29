import PhotosUI
import SwiftUI
import UIKit

// MARK: - Configuration

struct FLCaptureConfiguration {
  let title: String
  let subtitle: String?
  let maxPhotos: Int
  let showManualEntry: Bool
  let manualEntryLabel: String?

  init(
    title: String,
    subtitle: String? = nil,
    maxPhotos: Int = 3,
    showManualEntry: Bool = false,
    manualEntryLabel: String? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.maxPhotos = maxPhotos
    self.showManualEntry = showManualEntry
    self.manualEntryLabel = manualEntryLabel
  }
}

// MARK: - FLCaptureView

/// Full-screen camera capture with preview, shutter, thumbnails, and library/manual fallbacks.
struct FLCaptureView: View {
  private struct ThumbnailItem: Identifiable {
    let id: ObjectIdentifier
    let index: Int
    let image: UIImage
  }

  let configuration: FLCaptureConfiguration
  @Binding var capturedImages: [UIImage]
  let onDone: () -> Void
  let onManualEntry: (() -> Void)?

  @StateObject private var coordinator = FLCaptureSessionCoordinator()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var permissionState: CameraPermissionState = .checking
  @State private var shutterFlashOpacity: Double = 0
  @State private var shutterPressed = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var hasStartedSession = false

  private enum CameraPermissionState {
    case checking
    case ready
    case denied
    case unavailable
  }

  private var thumbnailItems: [ThumbnailItem] {
    capturedImages.enumerated().map { index, image in
      ThumbnailItem(id: ObjectIdentifier(image), index: index, image: image)
    }
  }

  init(
    configuration: FLCaptureConfiguration,
    capturedImages: Binding<[UIImage]>,
    onDone: @escaping () -> Void,
    onManualEntry: (() -> Void)? = nil
  ) {
    self.configuration = configuration
    self._capturedImages = capturedImages
    self.onDone = onDone
    self.onManualEntry = onManualEntry
  }

  var body: some View {
    ZStack {
      cameraLayer
        .ignoresSafeArea()

      gradientScrims
        .ignoresSafeArea()

      Color.white
        .opacity(shutterFlashOpacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      VStack(spacing: 0) {
        topChrome
        Spacer()

        if permissionState == .ready {
          viewfinderOverlay
          Spacer()
        }

        if !capturedImages.isEmpty {
          thumbnailStrip
            .padding(.bottom, AppTheme.Space.sm)
        }

        bottomDock
      }
    }
    .statusBarHidden(true)
    .task {
      await checkPermissionAndConfigure()
    }
    .onDisappear {
      hasStartedSession = false
      coordinator.shutdownSession()
    }
    .onChange(of: selectedPhotoItem) { _, newItem in
      guard let newItem else { return }
      loadFromLibrary(newItem)
    }
  }

  // MARK: - Camera Layer

  @ViewBuilder
  private var cameraLayer: some View {
    switch permissionState {
    case .checking:
      Color.black
    case .ready:
      FLCapturePreviewView(session: coordinator.captureSession)
        .opacity(coordinator.isCameraReady ? 1 : 0)
        .animation(reduceMotion ? nil : AppMotion.cameraReveal, value: coordinator.isCameraReady)
        .background(Color.black)
    case .denied, .unavailable:
      permissionFallback
    }
  }

  // MARK: - Gradient Scrims

  private var gradientScrims: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [Color.black.opacity(0.50), Color.black.opacity(0.0)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 140)

      Spacer()

      LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.60)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 180)
    }
    .allowsHitTesting(false)
  }

  // MARK: - Top Chrome

  private var topChrome: some View {
    HStack {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }

      Spacer()

      VStack(spacing: 2) {
        Text(configuration.title)
          .font(AppTheme.Typography.bodyMedium)
          .fontWeight(.semibold)
          .foregroundStyle(.white)

        if let subtitle = configuration.subtitle {
          Text(subtitle)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.70))
        }
      }

      Spacer()

      if capturedImages.count > 0 {
        Button {
          onDone()
          dismiss()
        } label: {
          Text("Done")
            .font(AppTheme.Typography.label)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.xxs)
            .background(.white.opacity(0.20), in: Capsule())
        }
      } else if coordinator.isFlashAvailable {
        Button {
          coordinator.isFlashOn.toggle()
        } label: {
          Image(
            systemName: coordinator.isFlashOn
              ? "bolt.fill"
              : "bolt.slash.fill"
          )
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(coordinator.isFlashOn ? .yellow : .white.opacity(0.7))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
        }
      } else {
        Color.clear.frame(width: 44, height: 44)
      }
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.top, AppTheme.Space.xs)
  }

  // MARK: - Viewfinder Overlay

  private var viewfinderOverlay: some View {
    GeometryReader { geo in
      let side = geo.size.width * 0.75
      let height = side * (4.0 / 3.0)

      FLViewfinderFrame()
        .frame(width: side, height: height)
        .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }
    .allowsHitTesting(false)
  }

  // MARK: - Thumbnail Strip

  private var thumbnailStrip: some View {
    HStack(spacing: AppTheme.Space.sm) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: AppTheme.Space.xs) {
          ForEach(thumbnailItems) { item in
            ZStack(alignment: .topTrailing) {
              Image(uiImage: item.image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.40), lineWidth: 1)
                )

              Button {
                withAnimation(reduceMotion ? nil : AppMotion.gentle) {
                  if item.index < capturedImages.count {
                    capturedImages.remove(at: item.index)
                  }
                }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 16))
                  .foregroundStyle(.white)
                  .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 16, height: 16))
              }
              .offset(x: 4, y: -4)
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
        }
        .padding(.horizontal, AppTheme.Space.md)
      }

      Text("\(capturedImages.count) of \(configuration.maxPhotos)")
        .font(.system(.caption, design: .rounded, weight: .bold))
        .foregroundStyle(.white.opacity(0.80))
        .contentTransition(.numericText())
        .padding(.trailing, AppTheme.Space.md)
    }
  }

  // MARK: - Bottom Dock

  private var bottomDock: some View {
    HStack(alignment: .center) {
      PhotosPicker(
        selection: $selectedPhotoItem,
        matching: .images,
        photoLibrary: .shared()
      ) {
        ZStack {
          Circle()
            .fill(.white.opacity(0.15))
            .frame(width: 44, height: 44)

          Image(systemName: "photo.on.rectangle")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 64)

      Spacer()

      shutterButton

      Spacer()

      if configuration.showManualEntry, let onManualEntry {
        Button {
          onManualEntry()
          dismiss()
        } label: {
          ZStack {
            Circle()
              .fill(.white.opacity(0.15))
              .frame(width: 44, height: 44)

            Image(systemName: "text.badge.plus")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 64)
      } else {
        Color.clear.frame(width: 64, height: 44)
      }
    }
    .padding(.horizontal, AppTheme.Space.lg)
    .padding(.bottom, AppTheme.Space.lg)
    .background(
      LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.4)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
  }

  // MARK: - Shutter Button

  private var shutterButton: some View {
    let isDisabled =
      capturedImages.count >= configuration.maxPhotos
      || permissionState != .ready
      || !coordinator.isCameraReady
      || coordinator.isCapturingPhoto

    return Button {
      guard !isDisabled else { return }
      capturePhoto()
    } label: {
      ZStack {
        Circle()
          .stroke(.white, lineWidth: 4)
          .frame(width: 72, height: 72)

        Circle()
          .fill(.white)
          .frame(width: 60, height: 60)
          .scaleEffect(shutterPressed ? 0.88 : 1.0)
          .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: shutterPressed)
      }
      .opacity(isDisabled ? 0.4 : 1.0)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in shutterPressed = true }
        .onEnded { _ in shutterPressed = false }
    )
  }

  // MARK: - Permission Fallback

  private var permissionFallback: some View {
    ZStack {
      LinearGradient(
        colors: [Color(white: 0.08), Color(white: 0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(spacing: AppTheme.Space.lg) {
        Image(systemName: "camera.fill")
          .font(.system(size: 36, weight: .medium))
          .foregroundStyle(.white.opacity(0.40))

        VStack(spacing: AppTheme.Space.sm) {
          Text(
            permissionState == .denied
              ? "Camera Access Required"
              : "Camera Unavailable"
          )
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(.white)

          Text(
            permissionState == .denied
              ? "Enable camera access in Settings to take photos."
              : "Use the photo library to select images."
          )
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(.white.opacity(0.60))
          .multilineTextAlignment(.center)
        }

        VStack(spacing: AppTheme.Space.sm) {
          if permissionState == .denied {
            Button {
              AppPermissionCenter.openAppSettings()
            } label: {
              Text("Open Settings")
                .font(AppTheme.Typography.label)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, AppTheme.Space.xl)
                .padding(.vertical, AppTheme.Space.sm)
                .background(.white.opacity(0.20), in: Capsule())
            }
          }

          PhotosPicker(
            selection: $selectedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
          ) {
            Text("Use Photo Library")
              .font(AppTheme.Typography.label)
              .foregroundStyle(.white.opacity(0.80))
              .padding(.horizontal, AppTheme.Space.xl)
              .padding(.vertical, AppTheme.Space.sm)
              .background(.white.opacity(0.10), in: Capsule())
          }
        }
      }
      .padding(AppTheme.Space.xl)
    }
  }

  // MARK: - Actions

  private func checkPermissionAndConfigure() async {
    guard !hasStartedSession else { return }

    let result = await AppPermissionCenter.request(.camera)

    if AppPermissionCenter.canProceed(result) {
      hasStartedSession = true
      permissionState = .ready
      coordinator.startSessionIfNeeded()
    } else {
      let status = AppPermissionCenter.status(for: .camera)
      switch status {
      case .unavailable:
        permissionState = .unavailable
      default:
        permissionState = .denied
      }
    }
  }

  private func capturePhoto() {
    AppPreferencesStore.haptic(.medium)
    let flashRequested = coordinator.isFlashOn

    withAnimation(reduceMotion ? nil : AppMotion.shutterFlash) {
      shutterFlashOpacity = 0.7
    }
    withAnimation(
      (reduceMotion ? nil : AppMotion.shutterFlash)?
        .delay(0.08)
    ) {
      shutterFlashOpacity = 0
    }

    Task {
      guard let image = await coordinator.capturePhoto(flashRequested: flashRequested) else {
        return
      }
      let processed = ScanImagePreprocessor.prepare(image)
      await appendCapturedImage(processed)
    }
  }

  private func loadFromLibrary(_ item: PhotosPickerItem) {
    Task {
      defer { selectedPhotoItem = nil }

      guard let data = try? await item.loadTransferable(type: Data.self),
        let image = UIImage(data: data)
      else { return }

      let processed = ScanImagePreprocessor.prepare(image)
      await appendCapturedImage(processed)
    }
  }

  @MainActor
  private func appendCapturedImage(_ image: UIImage) async {
    withAnimation(reduceMotion ? nil : AppMotion.thumbnailLand) {
      capturedImages.append(image)
    }

    guard capturedImages.count >= configuration.maxPhotos else { return }

    AppPreferencesStore.notification(.success)
    try? await Task.sleep(for: .milliseconds(500))
    onDone()
    dismiss()
  }
}
