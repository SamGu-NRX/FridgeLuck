import Foundation
import XCTest

private enum PrivacyManifestError: Error {
  case resourceMissing
  case rootNotDictionary
}

/// Validation rules mirroring `scripts/validate_privacy_manifest.py` (keep the two
/// tables in sync). Reason codes were copied verbatim from Apple's primary
/// documentation for the NSPrivacyAccessedAPIType key (retrieved 2026-10-09);
/// data-type and purpose values from the NSPrivacyCollectedDataType key doc.
private enum PrivacyRulebook {
  static let approvedReasons: [String: Set<String>] = [
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
  ]

  static let allowedDataTypes: Set<String> = [
    "NSPrivacyCollectedDataTypeName", "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypePhoneNumber", "NSPrivacyCollectedDataTypePhysicalAddress",
    "NSPrivacyCollectedDataTypeOtherUserContactInfo", "NSPrivacyCollectedDataTypeHealth",
    "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypePaymentInfo",
    "NSPrivacyCollectedDataTypeCreditInfo", "NSPrivacyCollectedDataTypeOtherFinancialInfo",
    "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeCoarseLocation",
    "NSPrivacyCollectedDataTypeSensitiveInfo", "NSPrivacyCollectedDataTypeContacts",
    "NSPrivacyCollectedDataTypeEmailsOrTextMessages", "NSPrivacyCollectedDataTypePhotosorVideos",
    "NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeGameplayContent",
    "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeBrowsingHistory", "NSPrivacyCollectedDataTypeSearchHistory",
    "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypeAdvertisingData", "NSPrivacyCollectedDataTypeOtherUsageData",
    "NSPrivacyCollectedDataTypeCrashData", "NSPrivacyCollectedDataTypePerformanceData",
    "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeEnvironmentScanning",
    "NSPrivacyCollectedDataTypeHands", "NSPrivacyCollectedDataTypeHead",
    "NSPrivacyCollectedDataTypeOtherDataTypes",
  ]

  static let allowedPurposes: Set<String> = [
    "NSPrivacyCollectedDataPurposeAppFunctionality",
    "NSPrivacyCollectedDataPurposeAnalytics",
    "NSPrivacyCollectedDataPurposeProductPersonalization",
    "NSPrivacyCollectedDataPurposeDeveloperAdvertising",
    "NSPrivacyCollectedDataPurposeThirdPartyAdvertising",
    "NSPrivacyCollectedDataPurposeDeveloperMarketing",
    "NSPrivacyCollectedDataPurposeOtherPurposes",
  ]

  static let allowedTopKeys: Set<String> = [
    "NSPrivacyTracking", "NSPrivacyTrackingDomains",
    "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes",
  ]

  static func validateStructure(_ manifest: [String: Any]) -> [String] {
    var errors: [String] = []
    for key in manifest.keys where !allowedTopKeys.contains(key) {
      errors.append("unknown top-level key \(key)")
    }

    let tracking = manifest["NSPrivacyTracking"]
    if tracking == nil {
      errors.append("missing required key NSPrivacyTracking")
    } else if !(tracking is Bool) {
      errors.append("NSPrivacyTracking must be a boolean")
    }

    if let domains = manifest["NSPrivacyTrackingDomains"] as? [String] {
      if tracking as? Bool == false && !domains.isEmpty {
        errors.append("NSPrivacyTrackingDomains must be empty when NSPrivacyTracking is false")
      }
    } else if manifest["NSPrivacyTrackingDomains"] != nil {
      errors.append("NSPrivacyTrackingDomains must be an array of strings")
    }

    var seenDataTypes = Set<String>()
    for (index, entry) in (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).enumerated() {
      let label = "NSPrivacyCollectedDataTypes[\(index)]"
      let type = entry["NSPrivacyCollectedDataType"] as? String
      guard let type, allowedDataTypes.contains(type) else {
        errors.append("\(label) has unknown NSPrivacyCollectedDataType")
        continue
      }
      if !seenDataTypes.insert(type).inserted {
        errors.append("\(label) repeats data type \(type)")
      }
      if !(entry["NSPrivacyCollectedDataTypeLinked"] is Bool) {
        errors.append("\(label) NSPrivacyCollectedDataTypeLinked must be a boolean")
      }
      if !(entry["NSPrivacyCollectedDataTypeTracking"] is Bool) {
        errors.append("\(label) NSPrivacyCollectedDataTypeTracking must be a boolean")
      }
      let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String]
      guard let purposes, !purposes.isEmpty else {
        errors.append("\(label) NSPrivacyCollectedDataTypePurposes must be a non-empty array")
        continue
      }
      for purpose in purposes where !allowedPurposes.contains(purpose) {
        errors.append("\(label) has unknown purpose \(purpose)")
      }
      if entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == true,
         tracking as? Bool == false {
        errors.append("\(label) declares tracking while NSPrivacyTracking is false")
      }
    }

    var seenCategories = Set<String>()
    for (index, entry) in (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).enumerated() {
      let label = "NSPrivacyAccessedAPITypes[\(index)]"
      guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
            let approved = approvedReasons[category] else {
        errors.append("\(label) has unknown NSPrivacyAccessedAPIType")
        continue
      }
      if !seenCategories.insert(category).inserted {
        errors.append("\(label) repeats category \(category)")
      }
      guard let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String],
            !reasons.isEmpty else {
        errors.append("\(label) NSPrivacyAccessedAPITypeReasons must be a non-empty array")
        continue
      }
      for reason in reasons where !approved.contains(reason) {
        errors.append("\(label) reason \(reason) is not approved for \(category)")
      }
    }

    return errors
  }

  static func validateAppExpectations(_ manifest: [String: Any]) -> [String] {
    var errors: [String] = []
    if manifest["NSPrivacyTracking"] as? Bool != false {
      errors.append("app expectation: NSPrivacyTracking must be false")
    }
    if manifest["NSPrivacyTrackingDomains"] as? [String] != [] {
      errors.append("app expectation: NSPrivacyTrackingDomains must be empty")
    }
    return errors
  }
}

/// Hosted packaging and content checks for the app privacy manifest.
/// These tests run inside FridgeLuck.app (TEST_HOST, project.yml), so Bundle.main
/// is the app bundle: asserting the resource here proves actual packaging, which a
/// repository-side plist parse cannot.
final class PrivacyManifestTests: XCTestCase {
  func testPrivacyManifestIsBundledInHostedApp() throws {
    XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "FridgeLuck.app",
                   "these tests must be hosted by the app bundle (TEST_HOST) for Bundle.main to be the app")
    let manifest = try loadManifest(from: .main)
    XCTAssertEqual(PrivacyRulebook.validateStructure(manifest), [])
    XCTAssertEqual(PrivacyRulebook.validateAppExpectations(manifest), [])
  }

  func testPrivacyManifestContentMatchesSourceBackedDeclarations() throws {
    let manifest = try loadManifest(from: .main)

    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])

    var accessedByCategory: [String: [String]] = [:]
    for entry in try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) {
      let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
      accessedByCategory[category] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
    }
    XCTAssertEqual(accessedByCategory["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
    XCTAssertEqual(accessedByCategory["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    XCTAssertEqual(Set(accessedByCategory.keys),
                   ["NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryFileTimestamp"])

    var collectedTypes = Set<String>()
    for entry in try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) {
      let type = try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)
      collectedTypes.insert(type)
      XCTAssertEqual(try XCTUnwrap(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool), true,
                     "\(type) must be declared linked (conservative posture)")
      XCTAssertEqual(try XCTUnwrap(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool), false,
                     "\(type) must not be declared tracking")
      XCTAssertEqual(try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String]),
                     ["NSPrivacyCollectedDataPurposeAppFunctionality"],
                     "\(type) must declare only app functionality")
    }
    XCTAssertEqual(collectedTypes, [
      "NSPrivacyCollectedDataTypeDeviceID",
      "NSPrivacyCollectedDataTypeOtherDataTypes",
      "NSPrivacyCollectedDataTypeOtherUserContent",
      "NSPrivacyCollectedDataTypePhotosorVideos",
      "NSPrivacyCollectedDataTypeAudioData",
      "NSPrivacyCollectedDataTypeHealth",
    ])
  }

  // MARK: - Mutations

  func testMutationMissingResourceFails() {
    XCTAssertThrowsError(try loadManifest(from: Bundle(for: Self.self)),
                         "the test bundle does not ship the manifest, so a missing resource must surface here")
  }

  func testMutationMalformedXMLFails() {
    XCTAssertThrowsError(try parse(Data("<plist><dict><key>NSPrivacyTracking</key>".utf8)))
  }

  func testMutationMissingRootTrackingKeyFails() {
    var manifest = validManifest()
    manifest.removeValue(forKey: "NSPrivacyTracking")
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationUnknownReasonCodeFails() {
    var manifest = validManifest()
    manifest["NSPrivacyAccessedAPITypes"] = [
      ["NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
       "NSPrivacyAccessedAPITypeReasons": ["ZZZZ.9"]],
    ]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationUnknownCategoryFails() {
    var manifest = validManifest()
    manifest["NSPrivacyAccessedAPITypes"] = [
      ["NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryTelepathy",
       "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]],
    ]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationUnknownCollectedDataTypeFails() {
    var manifest = validManifest()
    manifest["NSPrivacyCollectedDataTypes"] = [entry(dataType: "NSPrivacyCollectedDataTypeTelepathy")]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationMissingLinkedFlagFails() {
    var mutated = entry(dataType: "NSPrivacyCollectedDataTypeDeviceID")
    mutated.removeValue(forKey: "NSPrivacyCollectedDataTypeLinked")
    var manifest = validManifest()
    manifest["NSPrivacyCollectedDataTypes"] = [mutated]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationTrackingDataWhileTrackingDisabledFails() {
    var manifest = validManifest()
    manifest["NSPrivacyCollectedDataTypes"] = [entry(tracking: true)]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationUnknownPurposeFails() {
    var manifest = validManifest()
    manifest["NSPrivacyCollectedDataTypes"] = [entry(purposes: ["NSPrivacyCollectedDataPurposeWorldDomination"])]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  func testMutationTrackingDomainsWhileTrackingDisabledFails() {
    var manifest = validManifest()
    manifest["NSPrivacyTrackingDomains"] = ["example.com"]
    XCTAssertFalse(PrivacyRulebook.validateStructure(manifest).isEmpty)
  }

  // MARK: - Fixtures

  private func validManifest() -> [String: Any] {
    [
      "NSPrivacyTracking": false,
      "NSPrivacyTrackingDomains": [String](),
      "NSPrivacyAccessedAPITypes": [
        ["NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
         "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]],
      ],
      "NSPrivacyCollectedDataTypes": [entry()],
    ]
  }

  private func entry(dataType: String = "NSPrivacyCollectedDataTypeDeviceID",
                     tracking: Bool = false,
                     purposes: [String] = ["NSPrivacyCollectedDataPurposeAppFunctionality"]) -> [String: Any] {
    [
      "NSPrivacyCollectedDataType": dataType,
      "NSPrivacyCollectedDataTypeLinked": true,
      "NSPrivacyCollectedDataTypeTracking": tracking,
      "NSPrivacyCollectedDataTypePurposes": purposes,
    ]
  }

  // MARK: - Loading

  private func loadManifest(from bundle: Bundle) throws -> [String: Any] {
    guard let url = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
      throw PrivacyManifestError.resourceMissing
    }
    let data = try Data(contentsOf: url)
    return try parse(data)
  }

  private func parse(_ data: Data) throws -> [String: Any] {
    var format = PropertyListSerialization.PropertyListFormat.xml
    let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    guard let manifest = parsed as? [String: Any] else {
      throw PrivacyManifestError.rootNotDictionary
    }
    return manifest
  }
}
