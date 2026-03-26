import Foundation
import os

#if canImport(HealthKit)
  import HealthKit
#endif

extension Notification.Name {
  static let appleHealthDidUpdate = Notification.Name("AppleHealthDidUpdate")
}

private let appleHealthLogger = Logger(subsystem: "samgu.FridgeLuck", category: "AppleHealth")

enum AppleHealthTypeRegistry {
  #if canImport(HealthKit)
    static var requestShareTypes: Set<HKSampleType> {
      Set(quantityTypes)
    }

    static var requestReadTypes: Set<HKObjectType> {
      Set(quantityTypes)
    }

    static var authorizationStatusTypes: [HKObjectType] {
      quantityTypes.map { $0 as HKObjectType }
    }

    static var quantityTypes: [HKQuantityType] {
      quantityIdentifiers.compactMap(HKQuantityType.quantityType(forIdentifier:))
    }

    static var foodCorrelationType: HKCorrelationType? {
      HKCorrelationType.correlationType(forIdentifier: .food)
    }

    private static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
      .dietaryEnergyConsumed,
      .dietaryProtein,
      .dietaryCarbohydrates,
      .dietaryFatTotal,
      .dietaryFiber,
      .dietarySugar,
      .dietarySodium,
    ]

    static func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
      switch identifier {
      case .dietaryEnergyConsumed:
        return .kilocalorie()
      case .dietarySodium:
        return .gramUnit(with: .milli)
      default:
        return .gram()
      }
    }
  #endif
}

#if canImport(HealthKit)
  struct AppleHealthAuthorizationContext {
    let healthStore: HKHealthStore
    let requestShareTypes: Set<HKSampleType>
    let requestReadTypes: Set<HKObjectType>
  }
#else
  struct AppleHealthAuthorizationContext {}
#endif

final class AppleHealthService: AppleHealthServicing, @unchecked Sendable {
  #if canImport(HealthKit)
    private let healthStore: HKHealthStore

    var authorizationContext: AppleHealthAuthorizationContext {
      AppleHealthAuthorizationContext(
        healthStore: healthStore,
        requestShareTypes: AppleHealthTypeRegistry.requestShareTypes,
        requestReadTypes: AppleHealthTypeRegistry.requestReadTypes
      )
    }
  #endif

  init() {
    #if canImport(HealthKit)
      self.healthStore = HKHealthStore()
    #endif
  }

  func authorizationStatus() -> AppPermissionStatus {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

      let statuses = AppleHealthTypeRegistry.authorizationStatusTypes.map {
        healthStore.authorizationStatus(for: $0)
      }
      guard !statuses.isEmpty else { return .unavailable }

      if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
        return .authorized
      }

      if statuses.contains(.sharingDenied) {
        return .denied
      }

      return .notDetermined
    #else
      return .unavailable
    #endif
  }

  func authorizationRequestStatus() async -> AppleHealthAuthorizationRequestStatus {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

      return await withCheckedContinuation { continuation in
        healthStore.getRequestStatusForAuthorization(
          toShare: AppleHealthTypeRegistry.requestShareTypes,
          read: AppleHealthTypeRegistry.requestReadTypes
        ) { status, error in
          if let error {
            if self.isMissingHealthKitEntitlement(error) {
              continuation.resume(returning: .unavailable)
              return
            }

            appleHealthLogger.error(
              "Authorization preflight failed: \(error.localizedDescription, privacy: .public)"
            )
            continuation.resume(returning: .failed(error.localizedDescription))
            return
          }

          let normalizedStatus: AppleHealthAuthorizationRequestStatus
          switch status {
          case .shouldRequest:
            normalizedStatus = .shouldRequest
          case .unnecessary:
            normalizedStatus = .unnecessary
          case .unknown:
            normalizedStatus = .unknown
          @unknown default:
            normalizedStatus = .unknown
          }
          continuation.resume(returning: normalizedStatus)
        }
      }
    #else
      return .unavailable
    #endif
  }

  func writeMeal(_ record: AppleHealthMealRecord) async throws {
    #if canImport(HealthKit)
      guard authorizationStatus() == .authorized else { return }
      guard let correlation = makeFoodCorrelation(from: record) else { return }

      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        healthStore.save(correlation) { success, error in
          if let error {
            continuation.resume(throwing: error)
          } else if success {
            NotificationCenter.default.post(name: .appleHealthDidUpdate, object: nil)
            continuation.resume()
          } else {
            continuation.resume(
              throwing: NSError(
                domain: "AppleHealthService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Health data save failed."]
              )
            )
          }
        }
      }
    #endif
  }

  func fetchNutritionTotals(in interval: DateInterval) async throws -> AppleHealthNutritionTotals? {
    #if canImport(HealthKit)
      guard authorizationStatus() == .authorized else { return nil }

      async let calories = sum(for: .dietaryEnergyConsumed, interval: interval)
      async let protein = sum(for: .dietaryProtein, interval: interval)
      async let carbs = sum(for: .dietaryCarbohydrates, interval: interval)
      async let fat = sum(for: .dietaryFatTotal, interval: interval)
      async let fiber = sum(for: .dietaryFiber, interval: interval)
      async let sugar = sum(for: .dietarySugar, interval: interval)
      async let sodium = sum(for: .dietarySodium, interval: interval)

      return AppleHealthNutritionTotals(
        calories: try await calories,
        proteinGrams: try await protein,
        carbsGrams: try await carbs,
        fatGrams: try await fat,
        fiberGrams: try await fiber,
        sugarGrams: try await sugar,
        sodiumMilligrams: try await sodium
      )
    #else
      return nil
    #endif
  }

  func fetchDailyNutritionTotals(lastDays: Int, endingOn endDate: Date) async throws
    -> [AppleHealthNutritionDay]
  {
    #if canImport(HealthKit)
      guard authorizationStatus() == .authorized else { return [] }

      let safeDays = max(1, lastDays)
      let calendar = Calendar.current
      let endOfRangeDay = calendar.startOfDay(for: endDate)
      guard
        let startOfRangeDay = calendar.date(
          byAdding: .day, value: -(safeDays - 1), to: endOfRangeDay)
      else {
        return []
      }

      async let calories = dailySums(
        for: .dietaryEnergyConsumed,
        from: startOfRangeDay,
        to: endOfRangeDay
      )
      async let protein = dailySums(for: .dietaryProtein, from: startOfRangeDay, to: endOfRangeDay)
      async let carbs = dailySums(
        for: .dietaryCarbohydrates,
        from: startOfRangeDay,
        to: endOfRangeDay
      )
      async let fat = dailySums(for: .dietaryFatTotal, from: startOfRangeDay, to: endOfRangeDay)
      async let fiber = dailySums(for: .dietaryFiber, from: startOfRangeDay, to: endOfRangeDay)
      async let sugar = dailySums(for: .dietarySugar, from: startOfRangeDay, to: endOfRangeDay)
      async let sodium = dailySums(for: .dietarySodium, from: startOfRangeDay, to: endOfRangeDay)

      let caloriesByDay = try await calories
      let proteinByDay = try await protein
      let carbsByDay = try await carbs
      let fatByDay = try await fat
      let fiberByDay = try await fiber
      let sugarByDay = try await sugar
      let sodiumByDay = try await sodium

      return (0..<safeDays).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: offset, to: startOfRangeDay) else {
          return nil
        }

        return AppleHealthNutritionDay(
          date: date,
          totals: AppleHealthNutritionTotals(
            calories: caloriesByDay[date] ?? 0,
            proteinGrams: proteinByDay[date] ?? 0,
            carbsGrams: carbsByDay[date] ?? 0,
            fatGrams: fatByDay[date] ?? 0,
            fiberGrams: fiberByDay[date] ?? 0,
            sugarGrams: sugarByDay[date] ?? 0,
            sodiumMilligrams: sodiumByDay[date] ?? 0
          )
        )
      }
    #else
      return []
    #endif
  }

  #if canImport(HealthKit)
    private func isMissingHealthKitEntitlement(_ error: Error) -> Bool {
      let message = error.localizedDescription.lowercased()
      return message.contains("com.apple.developer.healthkit")
        || message.contains("missing")
          && message.contains("healthkit")
          && message.contains("entitlement")
    }

    private func makeFoodCorrelation(from record: AppleHealthMealRecord) -> HKCorrelation? {
      guard let correlationType = AppleHealthTypeRegistry.foodCorrelationType else { return nil }

      let samples = makeSamples(from: record)
      guard !samples.isEmpty else { return nil }

      return HKCorrelation(
        type: correlationType,
        start: record.date,
        end: record.date,
        objects: Set(samples),
        metadata: correlationMetadata(for: record)
      )
    }

    private func makeSamples(from record: AppleHealthMealRecord) -> [HKQuantitySample] {
      let fields: [(HKQuantityTypeIdentifier, Double)] = [
        (.dietaryEnergyConsumed, record.calories),
        (.dietaryProtein, record.proteinGrams),
        (.dietaryCarbohydrates, record.carbsGrams),
        (.dietaryFatTotal, record.fatGrams),
        (.dietaryFiber, record.fiberGrams),
        (.dietarySugar, record.sugarGrams),
        (.dietarySodium, record.sodiumMilligrams),
      ]

      return fields.compactMap { identifier, value in
        guard value > 0 else { return nil }
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        return HKQuantitySample(
          type: type,
          quantity: HKQuantity(
            unit: AppleHealthTypeRegistry.unit(for: identifier),
            doubleValue: value
          ),
          start: record.date,
          end: record.date,
          metadata: sampleMetadata(for: record, identifier: identifier)
        )
      }
    }

    private func correlationMetadata(for record: AppleHealthMealRecord) -> [String: Any] {
      [
        HKMetadataKeyFoodType: record.foodType,
        HKMetadataKeyExternalUUID: record.externalUUID,
        HKMetadataKeySyncIdentifier: record.syncIdentifier,
        HKMetadataKeySyncVersion: record.syncVersion,
      ]
    }

    private func sampleMetadata(
      for record: AppleHealthMealRecord,
      identifier: HKQuantityTypeIdentifier
    ) -> [String: Any] {
      [
        HKMetadataKeyExternalUUID: "\(record.externalUUID).\(identifier.rawValue)",
        HKMetadataKeySyncIdentifier: "\(record.syncIdentifier).\(identifier.rawValue)",
        HKMetadataKeySyncVersion: record.syncVersion,
      ]
    }

    private func sum(for identifier: HKQuantityTypeIdentifier, interval: DateInterval) async throws
      -> Double
    {
      guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
        return 0
      }

      let predicate = HKQuery.predicateForSamples(
        withStart: interval.start,
        end: interval.end,
        options: .strictStartDate
      )

      return try await withCheckedThrowingContinuation { continuation in
        let query = HKStatisticsQuery(
          quantityType: quantityType,
          quantitySamplePredicate: predicate,
          options: .cumulativeSum
        ) { _, result, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }

          let unit = AppleHealthTypeRegistry.unit(for: identifier)
          let total = result?.sumQuantity()?.doubleValue(for: unit) ?? 0
          continuation.resume(returning: total)
        }

        healthStore.execute(query)
      }
    }

    private func dailySums(
      for identifier: HKQuantityTypeIdentifier,
      from startDate: Date,
      to endDate: Date
    ) async throws -> [Date: Double] {
      guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
        return [:]
      }

      let calendar = Calendar.current
      guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDate) else {
        return [:]
      }

      let predicate = HKQuery.predicateForSamples(
        withStart: startDate,
        end: endExclusive,
        options: .strictStartDate
      )
      var intervalComponents = DateComponents()
      intervalComponents.day = 1

      return try await withCheckedThrowingContinuation { continuation in
        let query = HKStatisticsCollectionQuery(
          quantityType: quantityType,
          quantitySamplePredicate: predicate,
          options: .cumulativeSum,
          anchorDate: startDate,
          intervalComponents: intervalComponents
        )

        query.initialResultsHandler = { _, results, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }

          let unit = AppleHealthTypeRegistry.unit(for: identifier)
          var sumsByDay: [Date: Double] = [:]

          results?.enumerateStatistics(from: startDate, to: endExclusive) { statistics, _ in
            let day = calendar.startOfDay(for: statistics.startDate)
            let value = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
            sumsByDay[day] = value
          }

          continuation.resume(returning: sumsByDay)
        }

        healthStore.execute(query)
      }
    }
  #endif
}
