public enum PermissionStatus: Equatable, Sendable {
  case authorized
  case denied
  case restricted
  case notDetermined
  case limited
  case unavailable
}

public enum PermissionRequestResult: Equatable, Sendable {
  case granted
  case denied
  case limited
  case unavailable
}

public enum CapabilityStatus: Equatable, Sendable {
  case available
  case unavailable
}

public enum CameraAuthorizationState: Equatable, Sendable {
  case authorized
  case notDetermined
  case denied
  case restricted
  case unknown
}

public enum MicrophoneAuthorizationState: Equatable, Sendable {
  case granted
  case denied
  case undetermined
  case unknown
}

public enum PhotoAuthorizationState: Equatable, Sendable {
  case authorized
  case limited
  case denied
  case restricted
  case notDetermined
  case unknown
}

public enum PermissionMapping {
  public static func mapCameraStatus(
    cameraAvailable: Bool,
    authorizationState: CameraAuthorizationState
  ) -> PermissionStatus {
    guard cameraAvailable else { return .unavailable }

    switch authorizationState {
    case .authorized:
      return .authorized
    case .notDetermined:
      return .notDetermined
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    case .unknown:
      return .unavailable
    }
  }

  public static func mapMicrophoneStatus(
    _ state: MicrophoneAuthorizationState
  ) -> PermissionStatus {
    switch state {
    case .granted:
      return .authorized
    case .denied:
      return .denied
    case .undetermined:
      return .notDetermined
    case .unknown:
      return .unavailable
    }
  }

  public static func mapPhotoStatus(
    _ state: PhotoAuthorizationState
  ) -> PermissionStatus {
    switch state {
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
    case .unknown:
      return .unavailable
    }
  }

  public static func mapPhotoRequestResult(
    _ state: PhotoAuthorizationState
  ) -> PermissionRequestResult {
    switch state {
    case .authorized:
      return .granted
    case .limited:
      return .limited
    case .denied, .restricted, .notDetermined:
      return .denied
    case .unknown:
      return .unavailable
    }
  }

  public static func canProceed(_ result: PermissionRequestResult) -> Bool {
    switch result {
    case .granted, .limited:
      return true
    case .denied, .unavailable:
      return false
    }
  }

  public static func mapLiDARAvailability(_ hasLiDARCapability: Bool) -> CapabilityStatus {
    hasLiDARCapability ? .available : .unavailable
  }
}
