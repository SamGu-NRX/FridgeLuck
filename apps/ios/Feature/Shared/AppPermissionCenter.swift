import ARKit
import AVFAudio
import AVFoundation
import FLFeatureLogic
import Photos
import UIKit
import UserNotifications

enum AppPermission: Equatable {
  case camera
  case microphone
  case photoLibraryReadWrite
  case notifications
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
    case .notifications:
      assertionFailure("Use notificationStatus() for notification permissions.")
      return .notDetermined
    }
  }

  @MainActor
  static func notificationStatus() async -> AppPermissionStatus {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return mapNotificationSettings(settings)
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

    case .notifications:
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      switch mapNotificationSettings(settings) {
      case .authorized, .limited:
        return .granted
      case .denied, .restricted:
        return .denied
      case .notDetermined:
        do {
          let granted = try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
          )
          return PermissionMapping.mapNotificationRequestResult(granted: granted)
        } catch {
          return .unavailable
        }
      case .unavailable:
        return .unavailable
      }
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

  static func mapNotificationSettings(_ settings: UNNotificationSettings) -> AppPermissionStatus {
    PermissionMapping.mapNotificationStatus(
      mapNotificationAuthorizationState(settings.authorizationStatus)
    )
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

  private static func mapNotificationAuthorizationState(
    _ status: UNAuthorizationStatus
  ) -> NotificationAuthorizationState {
    switch status {
    case .authorized:
      return .authorized
    case .provisional:
      return .provisional
    case .ephemeral:
      return .ephemeral
    case .denied:
      return .denied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .unknown
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
