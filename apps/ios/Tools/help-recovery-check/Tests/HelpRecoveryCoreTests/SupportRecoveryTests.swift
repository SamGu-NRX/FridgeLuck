import XCTest

@testable import HelpRecoveryCore

/// Deterministic state/action fixtures pinning the recovery contract.
final class SupportRecoveryTests: XCTestCase {
  private let fullWiring = SupportHostWiring(
    canRetryScan: true, canChooseInput: true, canManualEntry: true,
    canRetryCloud: true, canRetryLocalSave: true)

  func testFullyWiredPlansAreExact() {
    let expected: [SupportRecoveryIssue: [SupportRecoveryAction.Kind]] = [
      .cameraAccessDenied: [.openPermissionSettings, .retryScan],
      .photoLibraryAccessDenied: [.openPermissionSettings, .chooseDifferentInput],
      .partialScan: [.retryScan, .manualEntry],
      .emptyRecognition: [.retryScan, .manualEntry],
      .cloudUnavailable: [.retryCloudRequest, .manualEntry],
      .localSaveFailed: [.retryLocalSave, .openDiagnosticsPreview],
      .healthAuthorizationIncomplete: [.openPermissionSettings],
      .notificationAuthorizationIncomplete: [.openPermissionSettings],
    ]
    for (issue, kinds) in expected {
      let plan = SupportRecoveryMapping.plan(for: issue, wiring: fullWiring)
      XCTAssertEqual(plan.actions.map(\.kind), kinds, "plan mismatch for \(issue)")
    }
  }

  func testUnwiredHostHidesInsteadOfDisabling() {
    let plan = SupportRecoveryMapping.plan(
      for: .partialScan, wiring: SupportHostWiring())
    XCTAssertTrue(plan.actions.isEmpty, "unwired actions must be filtered, not shown dead")
  }

  func testLocalSaveFailureAlwaysOffersDiagnosticsPreview() {
    let plan = SupportRecoveryMapping.plan(
      for: .localSaveFailed, wiring: SupportHostWiring())
    XCTAssertEqual(
      plan.actions.map(\.kind), [.openDiagnosticsPreview],
      "diagnostics preview is a real, local destination and must remain")
  }

  func testNoResetActionsExist() {
    for kind in SupportRecoveryAction.Kind.allCases {
      let raw = kind.rawValue.lowercased()
      for bad in ["reset", "wipe", "clear", "erase", "delete"] {
        XCTAssertFalse(raw.contains(bad), "recovery must never reset data: \(raw)")
      }
    }
  }

  func testEveryActionHasRealDestination() {
    for issue in SupportRecoveryIssue.allCases {
      let plan = SupportRecoveryMapping.plan(for: issue, wiring: fullWiring)
      XCTAssertFalse(plan.actions.isEmpty, "\(issue) must offer at least one real action")
      for action in plan.actions {
        switch action.kind {
        case .replayQuest:
          XCTAssertNotNil(action.questTitle, "replay needs a real quest destination")
        case .openPermissionSettings, .openDiagnosticsPreview:
          break
        case .retryScan, .chooseDifferentInput, .manualEntry,
          .retryCloudRequest, .retryLocalSave:
          XCTAssertTrue(action.requiresHostWiring)
        case .replayOnboarding:
          break
        }
      }
    }
  }

  func testIssueRawValuesAreStable() {
    XCTAssertEqual(SupportRecoveryIssue.cameraAccessDenied.rawValue, "cameraAccessDenied")
    XCTAssertEqual(SupportRecoveryIssue.partialScan.rawValue, "partialScan")
    XCTAssertEqual(SupportRecoveryIssue.cloudUnavailable.rawValue, "cloudUnavailable")
  }

  private let fixtureInput = SupportDiagnosticInput(
    appVersion: "1.2.0", buildNumber: "42", platformName: "iOS 26.0",
    toolchainLabel: "swift-tools 6.0",
    schemaInventory: ["scan-run-store", "notification-rules"],
    capabilityInventory: ["camera", "photoLibrary", "cloudAgent", "appleHealth", "notifications"],
    issues: [.partialScan, .localSaveFailed])

  func testExportContainsOnlyAllowlistedKeys() throws {
    let export = try SupportDiagnosticExportBuilder.build(input: fixtureInput).get()
    let data = try JSONEncoder().encode(export)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(SupportDiagnosticExportBuilder.validateEncoded(text))
  }

  func testExportSentinelsPresent() throws {
    let export = try SupportDiagnosticExportBuilder.build(input: fixtureInput).get()
    XCTAssertEqual(export.format, SupportDiagnosticExport.formatSentinel)
    XCTAssertEqual(
      export.errorCodes.sorted(),
      ["fl.scan.capture", "fl.scan.classification", "fl.scan.ocr", "fl.store.save"])
    XCTAssertEqual(export.issues, ["partialScan", "localSaveFailed"])
  }

  func testForbiddenKeysRejected() {
    let smuggled = #"{"format":"fl.support.export.v1","ocrCandidate":"chicken"}"#
    XCTAssertFalse(SupportDiagnosticExportBuilder.validateEncoded(smuggled))
    let missingSentinel = #"{"appSummary":{}}"#
    XCTAssertFalse(SupportDiagnosticExportBuilder.validateEncoded(missingSentinel))
  }

  func testCancellationYieldsNoPartialExport() {
    var calls = 0
    let result = SupportDiagnosticExportBuilder.build(input: fixtureInput) {
      calls += 1
      return true
    }
    guard case .failure(.cancelled) = result else {
      return XCTFail("expected cancelled")
    }
    XCTAssertGreaterThanOrEqual(calls, 1)
  }

  func testMidwayCancellationAlsoCancels() {
    var calls = 0
    let result = SupportDiagnosticExportBuilder.build(input: fixtureInput) {
      calls += 1
      return calls >= 2
    }
    guard case .failure(.cancelled) = result else {
      return XCTFail("expected cancelled midway")
    }
  }

  func testEmptyInputFailsFast() {
    let empty = SupportDiagnosticInput(
      appVersion: nil, buildNumber: nil, platformName: "iOS",
      toolchainLabel: "swift-tools 6.0", schemaInventory: [],
      capabilityInventory: [], issues: [])
    guard case .failure(.emptyInput) = SupportDiagnosticExportBuilder.build(input: empty)
    else { return XCTFail("expected emptyInput") }
  }
}
