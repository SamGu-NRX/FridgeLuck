import Foundation

/// Fixed, typed error-code ids allowed in a diagnostic export. No free
/// text, no raw payloads, no paths, no tokens.
public enum SupportErrorCode: String, Codable, Sendable, CaseIterable {
  case scanClassification = "fl.scan.classification"
  case scanOCR = "fl.scan.ocr"
  case scanCapture = "fl.scan.capture"
  case cloudRequest = "fl.cloud.request"
  case localSave = "fl.store.save"
  case healthAuthorization = "fl.health.authorization"
  case notificationAuthorization = "fl.notifications.authorization"
}

/// Mapping from a recovery issue to the allowlisted error codes it may cite.
public func errorCodes(for issue: SupportRecoveryIssue) -> [SupportErrorCode] {
  switch issue {
  case .cameraAccessDenied, .photoLibraryAccessDenied:
    return [.scanCapture]
  case .partialScan:
    return [.scanCapture, .scanOCR, .scanClassification]
  case .emptyRecognition:
    return [.scanClassification, .scanOCR]
  case .cloudUnavailable:
    return [.cloudRequest]
  case .localSaveFailed:
    return [.localSave]
  case .healthAuthorizationIncomplete:
    return [.healthAuthorization]
  case .notificationAuthorizationIncomplete:
    return [.notificationAuthorization]
  }
}

/// Input to the export builder. Only allowlisted, typed fields exist, so a
/// raw photo, OCR text, token, path, or profile/history payload cannot be
/// attached by construction.
public struct SupportDiagnosticInput: Codable, Sendable, Equatable {
  public let appVersion: String?
  public let buildNumber: String?
  public let platformName: String
  public let toolchainLabel: String
  public let schemaInventory: [String]
  public let capabilityInventory: [String]
  public let issues: [SupportRecoveryIssue]

  public init(
    appVersion: String?, buildNumber: String?, platformName: String,
    toolchainLabel: String, schemaInventory: [String],
    capabilityInventory: [String], issues: [SupportRecoveryIssue]
  ) {
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.platformName = platformName
    self.toolchainLabel = toolchainLabel
    self.schemaInventory = schemaInventory
    self.capabilityInventory = capabilityInventory
    self.issues = issues
  }
}

public enum SupportDiagnosticBuildError: Error, Equatable, Sendable {
  case cancelled
  case emptyInput
}

public struct SupportDiagnosticExport: Codable, Sendable, Equatable {
  public static let formatSentinel = "fl.support.export.v1"

  public let format: String
  public let appSummary: [String: String]
  public let toolchainSummary: String
  public let schemaInventory: [String]
  public let capabilityInventory: [String]
  public let errorCodes: [String]
  public let issues: [String]
}

public enum SupportDiagnosticExportBuilder {
  /// Builds the export, checking `isCancelled` between sections so a
  /// cancelled preview never returns a half-written payload.
  public static func build(
    input: SupportDiagnosticInput,
    isCancelled: @escaping () -> Bool = { false }
  ) -> Result<SupportDiagnosticExport, SupportDiagnosticBuildError> {
    guard !input.issues.isEmpty || !input.capabilityInventory.isEmpty else {
      return .failure(.emptyInput)
    }
    if isCancelled() { return .failure(.cancelled) }

    var appSummary: [String: String] = [:]
    if let v = input.appVersion { appSummary["appVersion"] = v }
    if let b = input.buildNumber { appSummary["buildNumber"] = b }
    appSummary["platform"] = input.platformName

    if isCancelled() { return .failure(.cancelled) }

    let codes = input.issues.flatMap { errorCodes(for: $0) }
    let export = SupportDiagnosticExport(
      format: SupportDiagnosticExport.formatSentinel,
      appSummary: appSummary,
      toolchainSummary: input.toolchainLabel,
      schemaInventory: input.schemaInventory,
      capabilityInventory: input.capabilityInventory,
      errorCodes: Array(Set(codes.map(\.rawValue))).sorted(),
      issues: input.issues.map(\.rawValue)
    )
    if isCancelled() { return .failure(.cancelled) }
    return .success(export)
  }

  /// Validates an encoded export: sentinel present, and none of the
  /// forbidden payload keys appear anywhere in the encoding.
  public static func validateEncoded(_ text: String) -> Bool {
    guard text.contains(SupportDiagnosticExport.formatSentinel) else { return false }
    let forbidden = [
      "ocr", "token", "path", "photo", "audio", "label", "profile",
      "history", "ingredient", "transcript", "image",
    ]
    let lowered = text.lowercased()
    return forbidden.allSatisfy { !lowered.contains($0) }
  }
}
