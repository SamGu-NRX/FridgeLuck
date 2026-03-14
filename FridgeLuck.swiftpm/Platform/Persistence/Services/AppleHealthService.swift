import Foundation

#if canImport(HealthKit)
  import HealthKit
#endif

enum AppleHealthTypeRegistry {
  #if canImport(HealthKit)
    static var shareTypes: Set<HKSampleType> {
      Set(quantityTypes)
    }

    static var readTypes: Set<HKObjectType> {
      Set(quantityTypes)
    }

    static var quantityTypes: [HKQuantityType] {
      quantityIdentifiers.compactMap(HKQuantityType.quantityType(forIdentifier:))
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

final class AppleHealthService: AppleHealthServicing, @unchecked Sendable {
  #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
  #endif

  func authorizationStatus() -> AppPermissionStatus {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

      let statuses = AppleHealthTypeRegistry.quantityTypes.map {
        healthStore.authorizationStatus(for: $0)
      }

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

  @MainActor
  func requestAuthorization() async -> AppPermissionRequestResult {
    #if canImport(HealthKit)
      guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

      return await withCheckedContinuation { continuation in
        healthStore.requestAuthorization(
          toShare: AppleHealthTypeRegistry.shareTypes,
          read: AppleHealthTypeRegistry.readTypes
        ) { success, _ in
          continuation.resume(returning: success ? .granted : .denied)
        }
      }
    #else
      return .unavailable
    #endif
  }

  func writeMeal(_ record: AppleHealthMealRecord) async throws {
    #if canImport(HealthKit)
      guard authorizationStatus() == .authorized else { return }

      let samples = makeSamples(from: record)
      guard !samples.isEmpty else { return }

      try await withCheckedThrowingContinuation { continuation in
        healthStore.save(samples) { success, error in
          if let error {
            continuation.resume(throwing: error)
          } else if success {
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

  func fetchTodayNutritionTotals() async throws -> AppleHealthNutritionTotals? {
    #if canImport(HealthKit)
      guard authorizationStatus() == .authorized else { return nil }

      async let calories = sum(for: .dietaryEnergyConsumed)
      async let protein = sum(for: .dietaryProtein)
      async let carbs = sum(for: .dietaryCarbohydrates)
      async let fat = sum(for: .dietaryFatTotal)
      async let fiber = sum(for: .dietaryFiber)
      async let sugar = sum(for: .dietarySugar)
      async let sodium = sum(for: .dietarySodium)

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

  #if canImport(HealthKit)
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
            unit: AppleHealthTypeRegistry.unit(for: identifier), doubleValue: value),
          start: record.date,
          end: record.date
        )
      }
    }

    private func sum(for identifier: HKQuantityTypeIdentifier) async throws -> Double {
      guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
        return 0
      }

      let calendar = Calendar.current
      let startOfDay = calendar.startOfDay(for: Date())
      let predicate = HKQuery.predicateForSamples(
        withStart: startOfDay,
        end: Date(),
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
  #endif
}
