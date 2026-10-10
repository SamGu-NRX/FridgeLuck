// Harness-only stand-in for the CoreGraphics module on Linux.
//
// Why this exists: production recognition sources import CoreGraphics, which does
// not exist in the Swift 6.4 Linux toolchain. This target provides the module name
// and only the symbols the harness needs.
//
// Geometry (CGPoint/CGSize/CGRect/CGFloat-as-used-by-geometry) ships with
// Foundation on this toolchain and is intentionally NOT duplicated: files that
// import both modules would see ambiguous types on first use.
//
// CGFloat must be a distinct struct (not a typealias of Double): the vendored GRDB
// sees this module via SwiftPM's shared build-path import visibility and extends
// CGFloat with DatabaseValueConvertible; a Double typealias would duplicate
// GRDB's existing Double conformance and fail the build.
//
// CGImage is an opaque image handle: the production ScanInput carries one; the
// harness never decodes pixels (OCR text arrives as input records), so an empty
// shell suffices.

public struct CGFloat: Sendable, Hashable, Comparable, CustomStringConvertible,
  ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
  public var storage: Double

  public init(_ value: Double) { storage = value }
  public init(_ value: Int) { storage = Double(value) }

  public init(floatLiteral value: Double) { storage = value }
  public init(integerLiteral value: Int64) { storage = Double(value) }

  public static func < (lhs: CGFloat, rhs: CGFloat) -> Bool { lhs.storage < rhs.storage }

  public var description: String { storage.description }
}

extension Double {
  /// `Double(self)` in GRDB's CGFloat database bridge resolves through here.
  public init(_ value: CGFloat) { self = value.storage }
}

public final class CGImage: @unchecked Sendable {
  public init() {}
}
