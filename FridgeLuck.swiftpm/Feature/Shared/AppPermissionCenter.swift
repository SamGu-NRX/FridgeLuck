import ARKit
import AVFoundation
import FLFeatureLogic
import Photos
import UIKit

enum AppPermission: Equatable {
  case camera
  case microphone
  case photoLibraryReadWrite
}

typealias AppPermissionStatus = PermissionStatus
typealias AppPermissionRequestResult = PermissionRequestResult

enum AppCapability: Equatable {
  case lidarDepth
}

typealias AppCapabilityStatus = CapabilityStatus

@MainActor
enum AppPermissionCenter {
  static func status(for permission: AppPermission) -> AppPermissionStatus {
    switch permission {
    case .camera:
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }
      return mapCameraAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video))
    case .microphone:
      return mapMicrophonePermission(AVAudioSession.sharedInstance().recordPermission)
    case .photoLibraryReadWrite:
      return mapPhotoAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
  }

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
      switch AVAudioSession.sharedInstance().recordPermission {
      case .granted:
        return .granted
      case .denied:
        return .denied
      case .undetermined:
        return await withCheckedContinuation { continuation in
          AVAudioSession.sharedInstance().requestRecordPermission { granted in
            continuation.resume(returning: granted ? .granted : .denied)
          }
        }
      @unknown default:
        return .unavailable
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

  static func mapMicrophonePermission(
    _ permission: AVAudioSession.RecordPermission
  ) -> AppPermissionStatus {
    PermissionMapping.mapMicrophoneStatus(mapMicrophoneAuthorizationState(permission))
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

  private static func mapMicrophoneAuthorizationState(
    _ permission: AVAudioSession.RecordPermission
  ) -> MicrophoneAuthorizationState {
    switch permission {
    case .granted:
      return .granted
    case .denied:
      return .denied
    case .undetermined:
      return .undetermined
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
}
