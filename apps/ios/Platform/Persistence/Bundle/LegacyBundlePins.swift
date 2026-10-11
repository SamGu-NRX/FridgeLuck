import CryptoKit
import Foundation

/// One ingredient row as the USDA catalog source ships it, in the shape the catalog
/// importer writes into the app database. `fdcId` restores the source identity the
/// original import dropped.
struct LegacyCatalogIngredient: Decodable, Sendable {
  let fdcId: Int64
  let name: String
  let calories: Double
  let protein: Double
  let carbs: Double
  let fat: Double
  let fiber: Double
  let sugar: Double
  let sodium: Double
  let notes: String?
  let description: String
  let categoryLabel: String
  let spriteGroup: String
  let spriteKey: String
}

private struct LegacyCatalogExport: Decodable {
  let catalogSource: String
  let rows: [LegacyCatalogIngredient]
}

struct LegacyBundleManifestPin: Decodable, Sendable {
  let slug: String
  let bundleId: String
  let dataFile: String
  let dataSha256: String
  let catalogExportFile: String
  let catalogExportSha256: String
  let expectedCatalogRowCount: Int
}

private struct LegacyBundleManifest: Decodable {
  let version: Int
  let pins: [LegacyBundleManifestPin]
}

/// A verified pinned payload: the exact bundle content a past public release
/// hydrated from, plus the catalog export covering its ingredient provenance.
struct PinnedBundlePayload: Sendable {
  let slug: String
  let bundleId: String
  let data: BundledData
  let dataSha256: String
  let catalog: [LegacyCatalogIngredient]
}

enum LegacyBundlePinError: Error, CustomStringConvertible {
  case manifestMissing
  case manifestCorrupt(String)
  case pinnedFileMissing(String)
  case pinnedFileCorrupt(file: String, reason: String)
  case pinnedFileHashMismatch(file: String, expected: String, actual: String)
  case pinnedCatalogRowCountMismatch(file: String, expected: Int, actual: Int)

  var description: String {
    switch self {
    case .manifestMissing:
      return "legacy bundle manifest is missing"
    case .manifestCorrupt(let reason):
      return "legacy bundle manifest is corrupt: \(reason)"
    case .pinnedFileMissing(let file):
      return "pinned legacy bundle file is missing: \(file)"
    case .pinnedFileCorrupt(let file, let reason):
      return "pinned legacy bundle file is corrupt: \(file) (\(reason))"
    case .pinnedFileHashMismatch(let file, let expected, let actual):
      return
        "pinned legacy bundle file failed integrity check: \(file) expected sha256 \(expected), "
        + "found \(actual)"
    case .pinnedCatalogRowCountMismatch(let file, let expected, let actual):
      return
        "pinned legacy bundle catalog export has \(actual) rows, manifest promises \(expected): "
        + "\(file)"
    }
  }
}

/// Loads and verifies the pinned prior bundle payloads the app ships for legacy
/// adoption. Every failure mode refuses loudly: the production refresh must not run
/// when the historical snapshots it would match against are incomplete or tampered
/// with, because then "this row is the bundle's" would be a guess.
enum LegacyBundlePins {
  /// Loads pins from a directory. In the app this is the LegacyBundles resource
  /// folder inside the bundle; tests point it at a fixture directory.
  static func load(from directory: URL) throws -> [PinnedBundlePayload] {
    let manifestUrl = directory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestUrl.path) else {
      throw LegacyBundlePinError.manifestMissing
    }
    let manifestData: Data
    do {
      manifestData = try Data(contentsOf: manifestUrl)
    } catch {
      throw LegacyBundlePinError.pinnedFileCorrupt(
        file: "manifest.json", reason: String(describing: error))
    }
    let manifest: LegacyBundleManifest
    do {
      manifest = try JSONDecoder().decode(LegacyBundleManifest.self, from: manifestData)
    } catch {
      throw LegacyBundlePinError.manifestCorrupt(String(describing: error))
    }
    guard !manifest.pins.isEmpty else {
      throw LegacyBundlePinError.manifestCorrupt("no pins listed")
    }

    return try manifest.pins.map { pin in
      try loadPin(pin, from: directory)
    }
  }

  private static func loadPin(_ pin: LegacyBundleManifestPin, from directory: URL)
    throws -> PinnedBundlePayload
  {
    let dataUrl = directory.appendingPathComponent(pin.dataFile)
    let catalogUrl = directory.appendingPathComponent(pin.catalogExportFile)
    for (name, url) in [(pin.dataFile, dataUrl), (pin.catalogExportFile, catalogUrl)] {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw LegacyBundlePinError.pinnedFileMissing(name)
      }
    }

    let dataBytes: Data
    do {
      dataBytes = try Data(contentsOf: dataUrl)
    } catch {
      throw LegacyBundlePinError.pinnedFileCorrupt(file: pin.dataFile, reason: "unreadable")
    }
    let actualDataHash = Self.sha256Hex(dataBytes)
    guard actualDataHash == pin.dataSha256 else {
      throw LegacyBundlePinError.pinnedFileHashMismatch(
        file: pin.dataFile, expected: pin.dataSha256, actual: actualDataHash)
    }

    let catalogBytes: Data
    do {
      catalogBytes = try Data(contentsOf: catalogUrl)
    } catch {
      throw LegacyBundlePinError.pinnedFileCorrupt(
        file: pin.catalogExportFile, reason: "unreadable")
    }
    let actualCatalogHash = Self.sha256Hex(catalogBytes)
    guard actualCatalogHash == pin.catalogExportSha256 else {
      throw LegacyBundlePinError.pinnedFileHashMismatch(
        file: pin.catalogExportFile, expected: pin.catalogExportSha256,
        actual: actualCatalogHash)
    }

    let bundled: BundledData
    do {
      bundled = try JSONDecoder().decode(BundledData.self, from: dataBytes)
    } catch {
      throw LegacyBundlePinError.pinnedFileCorrupt(
        file: pin.dataFile, reason: "undecodable: \(String(describing: error))")
    }
    try BundledDataValidator.validate(bundled)

    let catalog: [LegacyCatalogIngredient]
    do {
      catalog = try JSONDecoder().decode(LegacyCatalogExport.self, from: catalogBytes).rows
    } catch {
      throw LegacyBundlePinError.pinnedFileCorrupt(
        file: pin.catalogExportFile, reason: "undecodable: \(String(describing: error))")
    }
    guard catalog.count == pin.expectedCatalogRowCount else {
      throw LegacyBundlePinError.pinnedCatalogRowCountMismatch(
        file: pin.catalogExportFile,
        expected: pin.expectedCatalogRowCount,
        actual: catalog.count)
    }

    return PinnedBundlePayload(
      slug: pin.slug,
      bundleId: pin.bundleId,
      data: bundled,
      dataSha256: pin.dataSha256,
      catalog: catalog)
  }

  /// SHA-256 hex over raw payload bytes; used for pin integrity, distinct from the
  /// canonical row hashes in CanonicalHash.
  static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { Self.hexByte($0) }.joined()
  }

  private static func hexByte(_ byte: UInt8) -> String {
    let digits = "0123456789abcdef"
    let high = Int(byte) / 16
    let low = Int(byte) % 16
    return "\(digits[digits.index(digits.startIndex, offsetBy: high)])"
      + "\(digits[digits.index(digits.startIndex, offsetBy: low)])"
  }
}
