// Logging-only shim for Apple's `os` module on Linux.
//
// Scope guard: this shim exists exclusively so that production files which use
// `os.Logger` for diagnostics can compile on Linux, where no `os` module ships
// with the toolchain. It implements logging and nothing else. It must never be
// extended to stand in for functional Apple-framework APIs (UIKit, Vision,
// HealthKit, UserNotifications, ...); those features belong to the iOS app and
// stay out of the Linux logic build. The target is only wired into the package
// on Linux (see Package.swift) and discards messages, matching the behavior of
// logging on a platform without a unified logging system.
//
// The API surface mirrors the subset of `os.Logger` used by the compiled
// sources: `Logger(subsystem:category:)` plus `debug`, `info`, `notice`,
// `error`, and `fault` calls taking `OSLogMessage` string interpolation with
// `privacy:` arguments.

#if os(Linux)

/// Placeholder for `OSLog`; carries no behavior on Linux.
public struct OSLog: Sendable {
  /// Mirrors `OSLog.current`; a no-op on Linux.
  public static let current = OSLog()

  public init() {}
}

/// Placeholder for `OSLogPrivacy`; messages are always discarded on Linux.
public struct OSLogPrivacy: Sendable, Equatable {
  public static let `public` = OSLogPrivacy()
  public static let `private` = OSLogPrivacy()
  public static let secret = OSLogPrivacy()

  public init() {}
}

/// Placeholder for `OSLogEntrySortOrder`-style enums is intentionally absent:
/// no compiled source uses anything beyond `Logger` string logging.

/// Logging-only stand-in for `os.Logger`. All messages are discarded.
public struct Logger: Sendable {
  public init(subsystem: String, category: String) {}
  public init() {}

  public func debug(_ message: OSLogMessage) {}
  public func info(_ message: OSLogMessage) {}
  public func notice(_ message: OSLogMessage) {}
  public func error(_ message: OSLogMessage) {}
  public func fault(_ message: OSLogMessage) {}
  public func critical(_ message: OSLogMessage) {}
  public func log(_ message: OSLogMessage) {}
}

/// String-interpolation carrier accepted by the shim `Logger`. Values are
/// evaluated lazily and then dropped, so logging calls stay cheap on Linux.
public struct OSLogMessage: Sendable, ExpressibleByStringLiteral,
  ExpressibleByStringInterpolation
{
  public struct StringInterpolation: Sendable, StringInterpolationProtocol {
    public init(literalCapacity: Int, interpolationCount: Int) {}

    public mutating func appendLiteral(_ literal: String) {}

    public mutating func appendInterpolation<T>(
      _ value: @autoclosure @escaping () -> T,
      privacy: OSLogPrivacy = .private
    ) {}

    public mutating func appendInterpolation<T>(
      _ value: @autoclosure @escaping () -> T,
      alignment: OSLogStringAlignment,
      privacy: OSLogPrivacy = .private
    ) {}

    public mutating func appendInterpolation<T>(
      _ value: @autoclosure @escaping () -> T,
      format: OSLogIntegerFormatting,
      privacy: OSLogPrivacy = .private
    ) {}

    public mutating func appendInterpolation<T>(
      _ value: @autoclosure @escaping () -> T,
      formatStyle: OSLogFloatFormatting,
      privacy: OSLogPrivacy = .private
    ) {}
  }

  public init(stringLiteral value: String) {}
  public init(stringInterpolation: StringInterpolation) {}
}

/// Unused on Linux; present so call sites with `alignment:` compile.
public struct OSLogStringAlignment: Sendable {
  public init() {}
}

/// Unused on Linux; present so call sites with integer `format:` compile.
public struct OSLogIntegerFormatting: Sendable {
  public static let decimal = OSLogIntegerFormatting()
  public static let hex = OSLogIntegerFormatting()

  public init() {}
}

/// Unused on Linux; present so call sites with float `formatStyle:` compile.
public struct OSLogFloatFormatting: Sendable {
  public static let fixed = OSLogFloatFormatting()
  public static let significant = OSLogFloatFormatting()

  public init() {}
}

#endif
