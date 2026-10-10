import Foundation

// MARK: - Execution-source manifest
//
// Binds a report to the exact sources and transforms that produced it:
// every compiled Swift file under Sources/, plus Package.swift,
// Package.resolved (the GRDB pin), and the Scripts/ transforms. Paths are
// recorded relative to the package root (never absolute — the manifest must
// stay byte-reproducible across machines) and sorted for canonical form.
//
// The report embeds this manifest before signing; ReportVerifier recomputes
// the on-disk hashes at verification time and refuses the report when the
// executed sources no longer match it.

public enum SourceManifest {
  /// Locates the package root by walking up from this file's compiled
  /// location (Sources/StoragePerfCore/<here>) looking for Package.swift,
  /// falling back to the current directory. Returns the first directory
  /// containing Package.swift, or nil.
  public static func packageRoot() -> String? {
    var candidates: [String] = []
    let here = #filePath
    candidates.append(
      URL(fileURLWithPath: here).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path)
    candidates.append(FileManager.default.currentDirectoryPath)
    for start in candidates {
      var url = URL(fileURLWithPath: start).standardized
      for _ in 0...8 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
          return url.path
        }
        if url.path == "/" { break }
        url.deleteLastPathComponent()
      }
    }
    return nil
  }

  /// Relative paths hashed by the manifest, sorted. Directories that do not
  /// exist (e.g. an unrefreshed Real/ mirror) contribute nothing.
  public static func manifestPaths(root: String) throws -> [String] {
    let fm = FileManager.default
    var relative: [String] = []

    func addFilesUnder(_ subpath: String, extensions: Set<String>) throws {
      let dir = (root as NSString).appendingPathComponent(subpath)
      guard fm.fileExists(atPath: dir) else { return }
      let enumerator = fm.enumerator(atPath: dir)
      while let entry = enumerator?.nextObject() as? String {
        if extensions.contains((entry as NSString).pathExtension) {
          relative.append(
            ((subpath as NSString).appendingPathComponent(entry) as NSString)
              .standardizingPath)
        }
      }
    }

    try addFilesUnder("Sources", extensions: ["swift"])
    try addFilesUnder("Scripts", extensions: ["sh", "py"])
    for top in ["Package.swift", "Package.resolved"] {
      if fm.fileExists(atPath: (root as NSString).appendingPathComponent(top)) {
        relative.append(top)
      }
    }
    return relative.sorted()
  }

  /// Builds the manifest JSON: {files: [{path, sha256}], fileCount}.
  /// object pair order is irrelevant (canonical rendering sorts keys), but
  /// the files array is order-stable by construction (sorted paths).
  public static func build(root: String) throws -> JSON {
    let fm = FileManager.default
    var files: [JSON] = []
    for relative in try manifestPaths(root: root) {
      let absolute = (root as NSString).appendingPathComponent(relative)
      guard let bytes = fm.contents(atPath: absolute) else {
        throw ReportVerifier.Failure(reason: "source file unreadable: \(relative)")
      }
      files.append(.object([
        ("path", .string(relative)),
        ("sha256", .string(SHA256.hex(String(decoding: bytes, as: UTF8.self)))),
      ]))
    }
    return .object([
      ("files", .array(files)),
      ("fileCount", .int(Int64(files.count))),
    ])
  }

  /// Recomputes on-disk hashes under `root` and compares them to `manifest`.
  /// Throws on any drift: missing file, extra file, or hash mismatch. This is
  /// what makes the manifest a binding, not a decoration.
  public static func verify(manifest: JSON, root: String) throws {
    let fm = FileManager.default
    guard case .object(let pairs) = manifest else {
      throw ReportVerifier.Failure(reason: "sourceManifest is not an object")
    }
    let fields = Dictionary(uniqueKeysWithValues: pairs)
    guard case .array(let recorded)? = fields["files"] else {
      throw ReportVerifier.Failure(reason: "sourceManifest.files missing")
    }
    guard case .int(let count)? = fields["fileCount"], Int(count) == recorded.count else {
      throw ReportVerifier.Failure(reason: "sourceManifest.fileCount disagrees with files")
    }
    var recordedByPath: [String: String] = [:]
    for entry in recorded {
      guard case .object(let entryPairs) = entry else {
        throw ReportVerifier.Failure(reason: "sourceManifest entry is not an object")
      }
      let entryFields = Dictionary(uniqueKeysWithValues: entryPairs)
      guard case .string(let path)? = entryFields["path"],
        case .string(let sha)? = entryFields["sha256"]
      else {
        throw ReportVerifier.Failure(reason: "sourceManifest entry missing path or sha256")
      }
      recordedByPath[path] = sha
    }

    let expectedPaths = try manifestPaths(root: root)
    let recordedPaths = Set(recordedByPath.keys)
    let onDisk = Set(expectedPaths)
    if recordedPaths != onDisk {
      let missing = onDisk.subtracting(recordedPaths).sorted()
      let extra = recordedPaths.subtracting(onDisk).sorted()
      var reasons: [String] = []
      if !missing.isEmpty { reasons.append("unrecorded sources: \(missing.joined(separator: ", "))") }
      if !extra.isEmpty { reasons.append("missing sources: \(extra.joined(separator: ", "))") }
      throw ReportVerifier.Failure(reason: reasons.joined(separator: "; "))
    }
    for (path, sha) in recordedByPath.sorted(by: { $0.0 < $1.0 }) {
      let absolute = (root as NSString).appendingPathComponent(path)
      guard let bytes = fm.contents(atPath: absolute) else {
        throw ReportVerifier.Failure(reason: "recorded source now unreadable: \(path)")
      }
      let actual = SHA256.hex(String(decoding: bytes, as: UTF8.self))
      guard actual == sha else {
        throw ReportVerifier.Failure(reason: "source hash drift for \(path)")
      }
    }
  }
}
