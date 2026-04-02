import Foundation
import UIKit

extension Notification.Name {
  static let inventoryDidChange = Notification.Name("samgu.FridgeLuck.inventoryDidChange")
}

@MainActor
final class NotificationCoordinator {
  private let ruleRepository: NotificationRuleRepository
  private let permissionService: any NotificationPermissionServicing
  private let scheduler: NotificationScheduler
  private let syncService: any NotificationSyncServing
  private let inventoryRepository: InventoryRepository
  private let spoilageService: SpoilageService
  private let center: NotificationCenter

  private var observers: [NSObjectProtocol] = []

  init(
    ruleRepository: NotificationRuleRepository,
    permissionService: any NotificationPermissionServicing,
    scheduler: NotificationScheduler,
    syncService: any NotificationSyncServing,
    inventoryRepository: InventoryRepository,
    spoilageService: SpoilageService,
    center: NotificationCenter = .default
  ) {
    self.ruleRepository = ruleRepository
    self.permissionService = permissionService
    self.scheduler = scheduler
    self.syncService = syncService
    self.inventoryRepository = inventoryRepository
    self.spoilageService = spoilageService
    self.center = center
  }

  func start() {
    guard observers.isEmpty else { return }

    observeRefresh(for: .inventoryDidChange)
    observeRefresh(for: UIApplication.significantTimeChangeNotification)
    observeRefresh(for: NSNotification.Name.NSSystemTimeZoneDidChange)
  }

  func handleAppDidBecomeActive() async {
    start()
    await refreshFreshnessOpportunities()
  }

  func requestAuthorizationIfNeeded() async -> AppPermissionRequestResult {
    let result = await permissionService.requestAuthorizationIfNeeded()
    await refreshLocalSchedules()
    return result
  }

  func refreshLocalSchedules() async {
    do {
      try ruleRepository.markStaleFreshnessOpportunities()
      let rules = try ruleRepository.fetchAllRules()
      let opportunities = try ruleRepository.fetchScheduledOpportunities()
      let permissionStatus = await permissionService.status()
      try await scheduler.reconcile(
        rules: rules,
        opportunities: opportunities,
        permissionStatus: permissionStatus
      )
    } catch {
      #if DEBUG
        print("[NotificationCoordinator] Failed to refresh local schedules: \(error)")
      #endif
    }
  }

  func refreshFreshnessOpportunities() async {
    do {
      let rule = try ruleRepository.fetchRule(kind: .useSoonAlerts)

      guard rule.enabled else {
        await storeFreshnessOpportunities([])
        return
      }

      let inventoryItems = try inventoryRepository.fetchAllActiveItems()
      guard !inventoryItems.isEmpty else {
        await storeFreshnessOpportunities([])
        return
      }

      if let remoteOpportunities = try await syncService.fetchFreshnessOpportunities(
        rule: rule,
        inventoryItems: inventoryItems
      ) {
        await storeFreshnessOpportunities(remoteOpportunities)
      } else {
        let fallback = try makeLocalFallbackOpportunities(rule: rule)
        await storeFreshnessOpportunities(fallback)
      }
    } catch {
      #if DEBUG
        print("[NotificationCoordinator] Failed to refresh freshness opportunities: \(error)")
      #endif
      if let rule = try? ruleRepository.fetchRule(kind: .useSoonAlerts), rule.enabled {
        let fallback = (try? makeLocalFallbackOpportunities(rule: rule)) ?? []
        try? ruleRepository.replaceFreshnessOpportunities(with: fallback)
      }
      await refreshLocalSchedules()
    }
  }

  private func makeLocalFallbackOpportunities(rule: NotificationRule) throws
    -> [NotificationOpportunity]
  {
    let suggestions = try spoilageService.useSoonSuggestions(withinDays: 2, limit: 3)
    guard !suggestions.isEmpty else { return [] }

    let now = Date()
    let earliestSchedule = nextScheduleDate(hour: rule.hour, minute: rule.minute, from: now)
    let ids = suggestions.map(\.ingredientId).sorted()
    let names = suggestions.map(\.ingredientName)
    let expiryDates = suggestions.map(\.earliestExpiresAt)
    let idString = ids.map(String.init).joined(separator: "-")
    let dayKey = Self.opportunityDayFormatter.string(from: earliestSchedule)

    let payload = NotificationSyncOpportunityPayload(
      ingredientIds: ids,
      ingredientNames: names,
      expiresAt: expiryDates
    )
    let payloadEncoder = JSONEncoder()
    payloadEncoder.dateEncodingStrategy = .iso8601
    let payloadJSON =
      String(
        data: try payloadEncoder.encode(payload),
        encoding: .utf8
      ) ?? "{}"

    let previewNames = names.prefix(2).joined(separator: ", ")
    let remainingCount = max(0, names.count - 2)
    let bodyTail = remainingCount > 0 ? " and \(remainingCount) more" : ""

    return [
      NotificationOpportunity(
        id: "local-use-soon-\(dayKey)-\(idString)",
        kind: .useSoonDigest,
        title: "Use these ingredients soon",
        body: "\(previewNames)\(bodyTail) should be cooked before they slip past their best days.",
        scheduledAt: earliestSchedule,
        payloadJSON: payloadJSON,
        source: .local,
        status: .scheduled,
        updatedAt: now
      )
    ]
  }

  private func observeRefresh(for name: Notification.Name) {
    observers.append(
      center.addObserver(
        forName: name,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in
          await self.refreshFreshnessOpportunities()
        }
      }
    )
  }

  private func storeFreshnessOpportunities(_ opportunities: [NotificationOpportunity]) async {
    do {
      try ruleRepository.replaceFreshnessOpportunities(with: opportunities)
    } catch {
      #if DEBUG
        print("[NotificationCoordinator] Failed to store freshness opportunities: \(error)")
      #endif
    }
    await refreshLocalSchedules()
  }

  private func nextScheduleDate(hour: Int, minute: Int, from now: Date) -> Date {
    let calendar = Calendar.current
    let today =
      calendar.date(
        bySettingHour: hour,
        minute: minute,
        second: 0,
        of: now
      ) ?? now

    if today > now {
      return today
    }

    return calendar.date(byAdding: .day, value: 1, to: today) ?? today
  }

  private static let opportunityDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
