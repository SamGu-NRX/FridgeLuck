import Foundation
import UserNotifications

actor NotificationScheduler {
  private let center: any UserNotificationCenterClient
  private let calendar: Calendar

  init(
    center: any UserNotificationCenterClient = SystemUserNotificationCenterClient(),
    calendar: Calendar = .current
  ) {
    self.center = center
    self.calendar = calendar
  }

  func reconcile(
    rules: [NotificationRule],
    opportunities: [NotificationOpportunity],
    permissionStatus: AppPermissionStatus
  ) async throws {
    let knownMealIdentifiers = NotificationRuleKind.orderedMealKinds.map(\.notificationIdentifier)
    let pending = await center.pendingNotificationRequests()
    let staleFreshnessIdentifiers =
      pending
      .map(\.identifier)
      .filter { $0.hasPrefix("freshness.") }

    await center.removePendingNotificationRequests(
      withIdentifiers: knownMealIdentifiers + staleFreshnessIdentifiers
    )

    guard permissionStatus == .authorized || permissionStatus == .limited else { return }
    let now = Date()

    for rule in rules where rule.kind.isMealReminder && rule.enabled {
      let content = UNMutableNotificationContent()
      content.title = rule.kind.notificationTitle
      content.body = rule.kind.notificationBody
      content.sound = .default

      var components = DateComponents()
      components.calendar = calendar
      components.hour = rule.hour
      components.minute = rule.minute

      let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
      let request = UNNotificationRequest(
        identifier: rule.kind.notificationIdentifier,
        content: content,
        trigger: trigger
      )
      try await center.add(request)
    }

    for opportunity in opportunities
    where opportunity.status == .scheduled && opportunity.scheduledAt > now {
      let content = UNMutableNotificationContent()
      content.title = opportunity.title
      content.body = opportunity.body
      content.sound = .default
      content.userInfo["payload_json"] = opportunity.payloadJSON
      content.userInfo["kind"] = opportunity.kind.rawValue

      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, opportunity.scheduledAt.timeIntervalSinceNow),
        repeats: false
      )
      let request = UNNotificationRequest(
        identifier: "freshness.\(opportunity.id)",
        content: content,
        trigger: trigger
      )
      try await center.add(request)
    }
  }
}
