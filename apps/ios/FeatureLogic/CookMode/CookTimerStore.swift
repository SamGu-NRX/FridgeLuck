import Foundation

/// A device-owned cooking timer (LeChef §4.2): an absolute wall-clock deadline plus its pause
/// bookkeeping — the §11 `cook_timer` shape. The deadline is absolute, so a relaunch recomputes
/// `remaining = deadline − now` without having recorded the elapsed walk, and a deadline that
/// passed while the app was dead presents as fired — the notification already did its job.
public struct CookTimer: Equatable, Hashable, Sendable, Codable {
  public let id: String
  public let sessionID: String
  public let label: String
  /// Absolute wall-clock deadline. Recomputed on resume/adjust from the injected clock —
  /// never re-derived from durations after the fact.
  public internal(set) var deadline: Date
  /// Set when paused; the notification is cancelled and the remaining seconds are frozen.
  public internal(set) var pausedAt: Date?
  /// Seconds left when the pause happened; nil while running.
  public internal(set) var remainingWhenPausedSeconds: Double?
  /// When the cook (or the app, on relaunch) acknowledged the fired timer.
  public internal(set) var acknowledgedAt: Date?
  /// The duration the timer was created with, for the drain ring. Timers persisted before this
  /// field existed decode as nil and render deadline-only.
  public internal(set) var totalSeconds: Double?

  public init(id: String, sessionID: String, label: String, deadline: Date) {
    self.id = id
    self.sessionID = sessionID
    self.label = label
    self.deadline = deadline
    self.pausedAt = nil
    self.remainingWhenPausedSeconds = nil
    self.acknowledgedAt = nil
    self.totalSeconds = nil
  }

  init(id: String, sessionID: String, label: String, deadline: Date, totalSeconds: Double?) {
    self.id = id
    self.sessionID = sessionID
    self.label = label
    self.deadline = deadline
    self.pausedAt = nil
    self.remainingWhenPausedSeconds = nil
    self.acknowledgedAt = nil
    self.totalSeconds = totalSeconds
  }

  /// Restores a timer from its persisted row (LeChef §11) — absolute deadline, pause, and
  /// acknowledgment included. Fired state is not restored because it is not stored: the §11
  /// `fired_at` column stays NULL by design, since a timer is fired exactly when it is not
  /// paused and the deadline has passed (see `isFired(at:)`), so storing it would duplicate
  /// the deadline.
  public init(
    id: String, sessionID: String, label: String, deadline: Date, pausedAt: Date?,
    remainingWhenPausedSeconds: Double?, acknowledgedAt: Date?, totalSeconds: Double?
  ) {
    self.id = id
    self.sessionID = sessionID
    self.label = label
    self.deadline = deadline
    self.pausedAt = pausedAt
    self.remainingWhenPausedSeconds = remainingWhenPausedSeconds
    self.acknowledgedAt = acknowledgedAt
    self.totalSeconds = totalSeconds
  }

  /// Seconds left from `now`: 0 once the deadline has passed (running or paused aside —
  /// a paused timer reports its frozen remainder).
  public func remainingSeconds(from now: Date) -> Double {
    if let remainingWhenPausedSeconds {
      return max(0, remainingWhenPausedSeconds)
    }
    return max(0, deadline.timeIntervalSince(now))
  }

  /// True when the deadline has passed, whether or not anyone has acknowledged it.
  public func isFired(at now: Date) -> Bool {
    pausedAt == nil && deadline <= now
  }

  public var isPaused: Bool { pausedAt != nil }

  public var isAcknowledged: Bool { acknowledgedAt != nil }
}

/// What the device should do after a store mutation. The store never touches
/// `UNUserNotificationCenter` itself — the notification id is the timer id.
public enum CookTimerEffect: Equatable, Hashable, Sendable {
  case scheduleNotification(id: String, deadline: Date)
  case cancelNotification(id: String)
}

/// The timers of the active cook session, as a value: `create`, `adjust`, `pause`, `resume`,
/// `remove`, `active`, `pendingFired` (LeChef §15). Pure and `Codable`, so the whole store
/// round-trips through persistence and a kill loses nothing — timers survive the app.
public struct CookTimerStore: Equatable, Sendable, Codable {
  public private(set) var timers: [CookTimer]

  public init(timers: [CookTimer] = []) {
    self.timers = timers
  }

  // MARK: - Mutations

  /// Creates a timer with an absolute deadline and schedules its notification.
  ///
  /// The returned timer is the acknowledgment: nothing before this call treats the timer as
  /// existing (LeChef §4.2 — the device creates the timer, and only then is it acknowledged).
  /// Returns nil and changes nothing when `seconds` is not positive or `id` is already taken.
  public mutating func create(id: String, sessionID: String, label: String, durationSeconds: Double, now: Date) -> (timer: CookTimer, effects: [CookTimerEffect])? {
    guard durationSeconds > 0, !timers.contains(where: { $0.id == id }) else { return nil }
    let timer = CookTimer(id: id, sessionID: sessionID, label: label, deadline: now.addingTimeInterval(durationSeconds))
    timers.append(timer)
    return (timer, [.scheduleNotification(id: id, deadline: timer.deadline)])
  }

  /// Moves the deadline to `now + durationSeconds` — an "add two minutes" on a running timer.
  /// Returns nil when the timer is unknown, paused (adjust after resume), or not positive.
  public mutating func adjust(id: String, durationSeconds: Double, now: Date) -> [CookTimerEffect]? {
    guard let index = index(of: id), timers[index].pausedAt == nil, durationSeconds > 0 else { return nil }
    let deadline = now.addingTimeInterval(durationSeconds)
    timers[index].deadline = deadline
    timers[index].totalSeconds = durationSeconds
    return [.scheduleNotification(id: id, deadline: deadline)]
  }

  /// Freezes the remaining seconds and cancels the notification. Pausing an unknown, already
  /// paused, or already fired timer is a no-op (nil).
  public mutating func pause(id: String, now: Date) -> [CookTimerEffect]? {
    guard let index = index(of: id), timers[index].pausedAt == nil, !timers[index].isFired(at: now) else { return nil }
    timers[index].pausedAt = now
    timers[index].remainingWhenPausedSeconds = timers[index].deadline.timeIntervalSince(now)
    return [.cancelNotification(id: id)]
  }

  /// Recomputes a new absolute deadline from the frozen remainder and reschedules the
  /// notification. Resuming an unknown or running timer is a no-op (nil).
  public mutating func resume(id: String, now: Date) -> [CookTimerEffect]? {
    guard let index = index(of: id), let remaining = timers[index].remainingWhenPausedSeconds else { return nil }
    timers[index].pausedAt = nil
    timers[index].remainingWhenPausedSeconds = nil
    let deadline = now.addingTimeInterval(max(0, remaining))
    timers[index].deadline = deadline
    return [.scheduleNotification(id: id, deadline: deadline)]
  }

  /// Removes the timer and cancels its notification. Unknown ids are a no-op (nil).
  public mutating func remove(id: String) -> [CookTimerEffect]? {
    guard let index = index(of: id) else { return nil }
    timers.remove(at: index)
    return [.cancelNotification(id: id)]
  }

  /// Marks a fired timer acknowledged so it stops presenting as pending.
  public mutating func acknowledge(id: String, at now: Date) {
    guard let index = index(of: id) else { return }
    timers[index].acknowledgedAt = now
  }

  // MARK: - Reads

  /// The timers to render, in creation order — running and paused alike.
  public func active(now: Date) -> [CookTimer] {
    timers
  }

  /// Timers whose deadline has passed and that nobody has acknowledged yet, oldest deadline
  /// first. After an app kill, this is how a passed deadline presents as fired.
  public func pendingFired(now: Date) -> [CookTimer] {
    timers
      .filter { $0.isFired(at: now) && $0.acknowledgedAt == nil }
      .sorted { $0.deadline < $1.deadline }
  }

  func index(of id: String) -> Int? {
    timers.firstIndex { $0.id == id }
  }
}

extension CookTimerStore {
  /// What a clock jump means for the timers (LeChef §4.4): timers recompute from absolute
  /// deadlines on any jump; a backwards jump larger than a minute also pauses them and asks,
  /// because wall-clock deadlines ahead of the new "now" can no longer be trusted.
  public enum ClockJump: Equatable, Sendable {
    case none
    case forward
    case backward
  }

  public static func classifyClockJump(lastKnown: Date, now: Date) -> ClockJump {
    let delta = now.timeIntervalSince(lastKnown)
    if delta >= 60 { return .forward }
    if delta <= -60 { return .backward }
    return .none
  }

  /// Pauses every running timer — the "ask" side of a backwards clock jump. The remainder is
  /// frozen as of `frozenAsOf` (the last clock the app trusted), not the jumped-back `now` —
  /// freezing against the new clock would inflate it by the size of the jump. Paused timers
  /// and already-fired timers keep their state; returns the notifications to cancel.
  public mutating func pauseAll(now: Date, frozenAsOf: Date? = nil) -> [CookTimerEffect] {
    var effects: [CookTimerEffect] = []
    let freezeAt = frozenAsOf ?? now
    for index in timers.indices where timers[index].pausedAt == nil && !timers[index].isFired(at: max(now, freezeAt)) {
      timers[index].pausedAt = now
      timers[index].remainingWhenPausedSeconds = max(0, timers[index].deadline.timeIntervalSince(freezeAt))
      effects.append(.cancelNotification(id: timers[index].id))
    }
    return effects
  }
}
