import Foundation

/// A point in time, stored as whole milliseconds since the Unix epoch in UTC.
///
/// Events carry this type; all ordering and decay math is done on the
/// integer, which keeps replay deterministic regardless of host timezone
/// or clock format.
public struct Instant: Hashable, Comparable, Sendable {
    public let millisecondsSinceEpoch: Int64

    /// Fails on a negative value: this domain has no events before 1970.
    public init?(millisecondsSinceEpoch ms: Int64) {
        guard ms >= 0 else { return nil }
        self.millisecondsSinceEpoch = ms
    }

    /// Boundary adapter from the app's `Date`.
    public init(_ date: Date) {
        let ms = date.timeIntervalSince1970.millisecondPrecision
        self.millisecondsSinceEpoch = ms
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.millisecondsSinceEpoch < rhs.millisecondsSinceEpoch
    }

    public func advanced(byMilliseconds ms: Int64) -> Instant {
        Instant(millisecondsSinceEpoch: max(0, millisecondsSinceEpoch + ms))
            ?? Instant(millisecondsSinceEpoch: 0)!
    }

    /// Whole days between two instants (floor, UTC — no DST in UTC).
    public func days(to other: Instant) -> Int64 {
        (other.millisecondsSinceEpoch - millisecondsSinceEpoch) / 86_400_000
    }

    /// ISO-8601 UTC rendering for diagnostics and profile recency stamps:
    /// `2026-01-02T13:30:00Z`, with `.%03d` milliseconds inserted before `Z`
    /// when the instant is not whole-second.
    public var iso8601UTC: String {
        let seconds = millisecondsSinceEpoch / 1000
        let millis = millisecondsSinceEpoch % 1000
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return millis == 0 ? base + "Z" : String(format: "%@.%03dZ", base, millis)
    }
}

extension Double {
    /// Milliseconds with sub-millisecond precision dropped (floor), stable
    /// across platforms.
    var millisecondPrecision: Int64 {
        Int64((self * 1000.0).rounded(.towardZero))
    }
}
