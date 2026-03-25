import ARKit
import AVFAudio
import AVFoundation
import FLFeatureLogic
import Photos
import UIKit

#if canImport(HealthKit)
  import HealthKit
#endif

enum AppPermission: Equatable {
  case camera
  case microphone
  case photoLibraryReadWrite
  case healthKit
}

typealias AppPermissionStatus = PermissionStatus
typealias AppPermissionRequestResult = PermissionRequestResult

enum AppCapability: Equatable {
  case lidarDepth
}

typealias AppCapabilityStatus = CapabilityStatus

enum AppPermissionCenter {
  @MainActor
  static func status(for permission: AppPermission) -> AppPermissionStatus {
    switch permission {
    case .camera:
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }
      return mapCameraAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video))
    case .microphone:
      return mapMicrophonePermission(MicrophonePermissionBridge.currentStatus())
    case .photoLibraryReadWrite:
      return mapPhotoAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    case .healthKit:
      return mapHealthKitPermission(healthKitAuthorizationStatus())
    }
  }

  @MainActor
  static func request(_ permission: AppPermission) async -> AppPermissionRequestResult {
    switch permission {
    case .camera:
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }

      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        return .granted
      case .notDetermined:
        return await withCheckedContinuation { continuation in
          AVCaptureDevice.requestAccess(for: .video) { granted in
            continuation.resume(returning: granted ? .granted : .denied)
          }
        }
      case .denied, .restricted:
        return .denied
      @unknown default:
        return .unavailable
      }

    case .microphone:
      switch MicrophonePermissionBridge.currentStatus() {
      case .granted:
        return .granted
      case .denied:
        return .denied
      case .undetermined:
        return await withCheckedContinuation { continuation in
          MicrophonePermissionBridge.request { granted in
            continuation.resume(returning: granted ? .granted : .denied)
          }
        }
      }

    case .photoLibraryReadWrite:
      let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      switch currentStatus {
      case .authorized:
        return .granted
      case .limited:
        return .limited
      case .notDetermined:
        return await withCheckedContinuation { continuation in
          PHPhotoLibrary.requestAuthorization(for: .readWrite) { authorizationStatus in
            continuation.resume(
              returning: mapPhotoAuthorizationRequestResult(authorizationStatus)
            )
          }
        }
      case .denied, .restricted:
        return .denied
      @unknown default:
        return .unavailable
      }

    case .healthKit:
      return await requestHealthKitAuthorization()
    }
  }

  static func status(for capability: AppCapability) -> AppCapabilityStatus {
    switch capability {
    case .lidarDepth:
      let hasLiDARCapability =
        ARWorldTrackingConfiguration.isSupported
        && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
      return mapLiDARAvailability(hasLiDARCapability)
    }
  }

  @MainActor
  static func openAppSettings() {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    guard UIApplication.shared.canOpenURL(settingsURL) else { return }
    UIApplication.shared.open(settingsURL)
  }

  static func canProceed(_ result: AppPermissionRequestResult) -> Bool {
    PermissionMapping.canProceed(result)
  }

  static func mapCameraAuthorizationStatus(
    _ status: AVAuthorizationStatus
  ) -> AppPermissionStatus {
    PermissionMapping.mapCameraStatus(
      cameraAvailable: true,
      authorizationState: mapCameraAuthorizationState(status)
    )
  }

  fileprivate static func mapMicrophonePermission(
    _ permission: MicrophonePermissionBridge.NormalizedPermission
  ) -> AppPermissionStatus {
    let state: MicrophoneAuthorizationState
    switch permission {
    case .granted:
      state = .granted
    case .denied:
      state = .denied
    case .undetermined:
      state = .undetermined
    }
    return PermissionMapping.mapMicrophoneStatus(state)
  }

  fileprivate static func mapHealthKitPermission(
    _ permission: HealthKitPermissionBridge.NormalizedPermission
  ) -> AppPermissionStatus {
    switch permission {
    case .authorized:
      return .authorized
    case .denied:
      return .denied
    case .notDetermined:
      return .notDetermined
    case .unavailable:
      return .unavailable
    }
  }

  static func mapPhotoAuthorizationStatus(
    _ status: PHAuthorizationStatus
  ) -> AppPermissionStatus {
    PermissionMapping.mapPhotoStatus(mapPhotoAuthorizationState(status))
  }

  static func mapPhotoAuthorizationRequestResult(
    _ status: PHAuthorizationStatus
  ) -> AppPermissionRequestResult {
    PermissionMapping.mapPhotoRequestResult(mapPhotoAuthorizationState(status))
  }

  static func mapLiDARAvailability(_ hasLiDARCapability: Bool) -> AppCapabilityStatus {
    PermissionMapping.mapLiDARAvailability(hasLiDARCapability)
  }

  private static func mapCameraAuthorizationState(
    _ status: AVAuthorizationStatus
  ) -> CameraAuthorizationState {
    switch status {
    case .authorized:
      return .authorized
    case .notDetermined:
      return .notDetermined
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    @unknown default:
      return .unknown
    }
  }

  private static func mapPhotoAuthorizationState(
    _ status: PHAuthorizationStatus
  ) -> PhotoAuthorizationState {
    switch status {
    case .authorized:
      return .authorized
    case .limited:
      return .limited
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .unknown
    }
  }

  private static func healthKitAuthorizationStatus()
    -> HealthKitPermissionBridge.NormalizedPermission
  {
    HealthKitPermissionBridge.currentStatus()
  }

  @MainActor
  private static func requestHealthKitAuthorization() async -> AppPermissionRequestResult {
    switch HealthKitPermissionBridge.currentStatus() {
    case .authorized:
      return .granted
    case .denied:
      return .denied
    case .unavailable:
      return .unavailable
    case .notDetermined:
      return await HealthKitPermissionBridge.request()
    }
  }
}

private enum MicrophonePermissionBridge {
  enum NormalizedPermission {
    case granted
    case denied
    case undetermined
  }

  static func currentStatus() -> NormalizedPermission {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted:
        return .granted
      case .denied:
        return .denied
      case .undetermined:
        return .undetermined
      @unknown default:
        return .undetermined
      }
    } else {
      switch AVAudioSession.sharedInstance().recordPermission {
      case .granted:
        return .granted
      case .denied:
        return .denied
      case .undetermined:
        return .undetermined
      @unknown default:
        return .undetermined
      }
    }
  }

  static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: completion)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }
  }
}

private enum HealthKitPermissionBridge {
  enum NormalizedPermission {
    case authorized
    case denied
    case notDetermined
    case unavailable
  }

  static func currentStatus() -> NormalizedPermission {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
      let store = HKHealthStore()
      let statuses = AppleHealthTypeRegistry.quantityTypes.map {
        store.authorizationStatus(for: $0)
      }

      if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
        return .authorized
      }

      if statuses.contains(.sharingDenied) {
        return .denied
      }

      return .notDetermined
    #else
      return .unavailable
    #endif
  }

  @MainActor
  static func request() async -> AppPermissionRequestResult {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
      let store = HKHealthStore()

      return await withCheckedContinuation { continuation in
        store.requestAuthorization(
          toShare: AppleHealthTypeRegistry.shareTypes,
          read: AppleHealthTypeRegistry.readTypes
        ) { success, _ in
          continuation.resume(returning: success ? .granted : .denied)
        }
      }
    #else
      return .unavailable
    #endif
  }
}
