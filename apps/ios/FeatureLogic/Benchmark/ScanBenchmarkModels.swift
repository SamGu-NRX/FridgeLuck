import Foundation

public enum ScanBenchmarkMetricStatus: String, Codable, Sendable {
  case measured
  case failed
  case notSupported
}

public enum ScanBenchmarkStatus: String, Codable, Sendable {
  case passed
  case regressed
  case invalid
}

public enum ScanBenchmarkDetectionBucket: String, Codable, Sendable {
  case auto
  case confirm
  case possible
  case unknown
}

public struct ScanBenchmarkGates: Sendable, Codable, Equatable {
  public let minimumDetectionF1: Double
  public let minimumCorrectionCoverage: Double
  public let minimumOCRFieldAccuracy: Double
  public let minimumReliabilityJaccard: Double
  public let targetMedianElapsedMs: Int

  public init(
    minimumDetectionF1: Double,
    minimumCorrectionCoverage: Double,
    minimumOCRFieldAccuracy: Double,
    minimumReliabilityJaccard: Double,
    targetMedianElapsedMs: Int
  ) {
    self.minimumDetectionF1 = minimumDetectionF1
    self.minimumCorrectionCoverage = minimumCorrectionCoverage
    self.minimumOCRFieldAccuracy = minimumOCRFieldAccuracy
    self.minimumReliabilityJaccard = minimumReliabilityJaccard
    self.targetMedianElapsedMs = targetMedianElapsedMs
  }
}

public struct ScanBenchmarkExpectedNutrition: Sendable, Codable, Equatable {
  public let caloriesPerServing: Double?
  public let servingSize: String?
  public let servingsPerContainer: Double?

  public init(
    caloriesPerServing: Double? = nil,
    servingSize: String? = nil,
    servingsPerContainer: Double? = nil
  ) {
    self.caloriesPerServing = caloriesPerServing
    self.servingSize = servingSize
    self.servingsPerContainer = servingsPerContainer
  }
}

public struct ScanBenchmarkCorpusEntry: Sendable, Codable, Equatable {
  public let id: String
  public let resourceName: String
  public let resourceExtension: String
  public let resourceSubdirectory: String?
  public let scenarioTags: [String]
  public let expectedIngredientIds: [Int64]
  public let expectedNutrition: ScanBenchmarkExpectedNutrition?

  public init(
    id: String,
    resourceName: String,
    resourceExtension: String,
    resourceSubdirectory: String? = nil,
    scenarioTags: [String],
    expectedIngredientIds: [Int64],
    expectedNutrition: ScanBenchmarkExpectedNutrition? = nil
  ) {
    self.id = id
    self.resourceName = resourceName
    self.resourceExtension = resourceExtension
    self.resourceSubdirectory = resourceSubdirectory
    self.scenarioTags = scenarioTags
    self.expectedIngredientIds = expectedIngredientIds
    self.expectedNutrition = expectedNutrition
  }
}

public struct ScanBenchmarkCorpus: Sendable, Codable, Equatable {
  public let iterations: Int
  public let gates: ScanBenchmarkGates
  public let images: [ScanBenchmarkCorpusEntry]

  public init(
    iterations: Int,
    gates: ScanBenchmarkGates,
    images: [ScanBenchmarkCorpusEntry]
  ) {
    self.iterations = iterations
    self.gates = gates
    self.images = images
  }
}

public struct ScanBenchmarkObservedDetection: Sendable, Codable, Equatable {
  public let ingredientId: Int64
  public let alternativeIngredientIds: [Int64]
  public let bucket: ScanBenchmarkDetectionBucket

  public init(
    ingredientId: Int64,
    alternativeIngredientIds: [Int64] = [],
    bucket: ScanBenchmarkDetectionBucket
  ) {
    self.ingredientId = ingredientId
    self.alternativeIngredientIds = alternativeIngredientIds
    self.bucket = bucket
  }
}

public struct ScanBenchmarkObservedNutrition: Sendable, Codable, Equatable {
  public let caloriesPerServing: Double?
  public let servingSize: String?
  public let servingsPerContainer: Double?

  public init(
    caloriesPerServing: Double? = nil,
    servingSize: String? = nil,
    servingsPerContainer: Double? = nil
  ) {
    self.caloriesPerServing = caloriesPerServing
    self.servingSize = servingSize
    self.servingsPerContainer = servingsPerContainer
  }
}

public struct ScanBenchmarkRunObservation: Sendable, Codable, Equatable {
  public let iteration: Int
  public let detections: [ScanBenchmarkObservedDetection]
  public let nutrition: ScanBenchmarkObservedNutrition?
  public let elapsedMs: Int
  public let passErrors: [String]
  public let errorDescription: String?

  public init(
    iteration: Int,
    detections: [ScanBenchmarkObservedDetection],
    nutrition: ScanBenchmarkObservedNutrition? = nil,
    elapsedMs: Int,
    passErrors: [String] = [],
    errorDescription: String? = nil
  ) {
    self.iteration = iteration
    self.detections = detections
    self.nutrition = nutrition
    self.elapsedMs = elapsedMs
    self.passErrors = passErrors
    self.errorDescription = errorDescription
  }
}

public struct ScanBenchmarkRunReport: Sendable, Codable, Equatable {
  public let iteration: Int
  public let ingredientIds: [Int64]
  public let alternativeIngredientIds: [Int64]
  public let elapsedMs: Int
  public let valid: Bool
  public let invalidReason: String?
  public let errorDescription: String?
  public let passErrors: [String]

  public init(
    iteration: Int,
    ingredientIds: [Int64],
    alternativeIngredientIds: [Int64],
    elapsedMs: Int,
    valid: Bool,
    invalidReason: String?,
    errorDescription: String?,
    passErrors: [String]
  ) {
    self.iteration = iteration
    self.ingredientIds = ingredientIds
    self.alternativeIngredientIds = alternativeIngredientIds
    self.elapsedMs = elapsedMs
    self.valid = valid
    self.invalidReason = invalidReason
    self.errorDescription = errorDescription
    self.passErrors = passErrors
  }
}

public struct ScanBenchmarkDetectionMetrics: Sendable, Codable, Equatable {
  public let status: ScanBenchmarkMetricStatus
  public let precision: Double?
  public let recall: Double?
  public let f1: Double?
  public let expectedIngredientCount: Int
  public let averageDetectedCount: Double?

  public init(
    status: ScanBenchmarkMetricStatus,
    precision: Double?,
    recall: Double?,
    f1: Double?,
    expectedIngredientCount: Int,
    averageDetectedCount: Double?
  ) {
    self.status = status
    self.precision = precision
    self.recall = recall
    self.f1 = f1
    self.expectedIngredientCount = expectedIngredientCount
    self.averageDetectedCount = averageDetectedCount
  }
}

public struct ScanBenchmarkCorrectionMetrics: Sendable, Codable, Equatable {
  public let status: ScanBenchmarkMetricStatus
  public let topPredictionAcceptanceRate: Double?
  public let alternativeCoverageRate: Double?
  public let missedExpectationCount: Int

  public init(
    status: ScanBenchmarkMetricStatus,
    topPredictionAcceptanceRate: Double?,
    alternativeCoverageRate: Double?,
    missedExpectationCount: Int
  ) {
    self.status = status
    self.topPredictionAcceptanceRate = topPredictionAcceptanceRate
    self.alternativeCoverageRate = alternativeCoverageRate
    self.missedExpectationCount = missedExpectationCount
  }
}

public struct ScanBenchmarkCalibrationMetric: Sendable, Codable, Equatable {
  public let bucket: ScanBenchmarkDetectionBucket
  public let status: ScanBenchmarkMetricStatus
  public let sampleCount: Int
  public let matchedCount: Int
  public let precision: Double?

  public init(
    bucket: ScanBenchmarkDetectionBucket,
    status: ScanBenchmarkMetricStatus,
    sampleCount: Int,
    matchedCount: Int,
    precision: Double?
  ) {
    self.bucket = bucket
    self.status = status
    self.sampleCount = sampleCount
    self.matchedCount = matchedCount
    self.precision = precision
  }
}

public struct ScanBenchmarkOCRMetrics: Sendable, Codable, Equatable {
  public let status: ScanBenchmarkMetricStatus
  public let parseSuccessRate: Double?
  public let caloriesAccuracy: Double?
  public let servingSizeAccuracy: Double?
  public let servingsPerContainerAccuracy: Double?

  public init(
    status: ScanBenchmarkMetricStatus,
    parseSuccessRate: Double?,
    caloriesAccuracy: Double?,
    servingSizeAccuracy: Double?,
    servingsPerContainerAccuracy: Double?
  ) {
    self.status = status
    self.parseSuccessRate = parseSuccessRate
    self.caloriesAccuracy = caloriesAccuracy
    self.servingSizeAccuracy = servingSizeAccuracy
    self.servingsPerContainerAccuracy = servingsPerContainerAccuracy
  }
}

public struct ScanBenchmarkLatencyMetrics: Sendable, Codable, Equatable {
  public let status: ScanBenchmarkMetricStatus
  public let medianElapsedMs: Int?
  public let p90ElapsedMs: Int?
  public let targetMedianElapsedMs: Int

  public init(
    status: ScanBenchmarkMetricStatus,
    medianElapsedMs: Int?,
    p90ElapsedMs: Int?,
    targetMedianElapsedMs: Int
  ) {
    self.status = status
    self.medianElapsedMs = medianElapsedMs
    self.p90ElapsedMs = p90ElapsedMs
    self.targetMedianElapsedMs = targetMedianElapsedMs
  }
}

public struct ScanBenchmarkReliabilityMetrics: Sendable, Codable, Equatable {
  public let status: ScanBenchmarkMetricStatus
  public let validRunCount: Int
  public let invalidRunCount: Int
  public let meanJaccardVsFirstValid: Double?
  public let minJaccardVsFirstValid: Double?
  public let requiredJaccard: Double

  public init(
    status: ScanBenchmarkMetricStatus,
    validRunCount: Int,
    invalidRunCount: Int,
    meanJaccardVsFirstValid: Double?,
    minJaccardVsFirstValid: Double?,
    requiredJaccard: Double
  ) {
    self.status = status
    self.validRunCount = validRunCount
    self.invalidRunCount = invalidRunCount
    self.meanJaccardVsFirstValid = meanJaccardVsFirstValid
    self.minJaccardVsFirstValid = minJaccardVsFirstValid
    self.requiredJaccard = requiredJaccard
  }
}

public struct ScanBenchmarkUnsupportedMetric: Sendable, Codable, Equatable {
  public let name: String
  public let status: ScanBenchmarkMetricStatus
  public let reason: String

  public init(
    name: String,
    status: ScanBenchmarkMetricStatus,
    reason: String
  ) {
    self.name = name
    self.status = status
    self.reason = reason
  }
}

public struct ScanBenchmarkImageReport: Sendable, Codable, Equatable {
  public let id: String
  public let scenarioTags: [String]
  public let expectedIngredientIds: [Int64]
  public let runs: [ScanBenchmarkRunReport]
  public let status: ScanBenchmarkStatus
  public let invalidReason: String?
  public let detectionMetrics: ScanBenchmarkDetectionMetrics
  public let correctionMetrics: ScanBenchmarkCorrectionMetrics
  public let calibrationMetrics: [ScanBenchmarkCalibrationMetric]
  public let ocrMetrics: ScanBenchmarkOCRMetrics
  public let latencyMetrics: ScanBenchmarkLatencyMetrics
  public let reliabilityMetrics: ScanBenchmarkReliabilityMetrics
  public let localizationMetric: ScanBenchmarkUnsupportedMetric
  public let amountMetric: ScanBenchmarkUnsupportedMetric

  public init(
    id: String,
    scenarioTags: [String],
    expectedIngredientIds: [Int64],
    runs: [ScanBenchmarkRunReport],
    status: ScanBenchmarkStatus,
    invalidReason: String?,
    detectionMetrics: ScanBenchmarkDetectionMetrics,
    correctionMetrics: ScanBenchmarkCorrectionMetrics,
    calibrationMetrics: [ScanBenchmarkCalibrationMetric],
    ocrMetrics: ScanBenchmarkOCRMetrics,
    latencyMetrics: ScanBenchmarkLatencyMetrics,
    reliabilityMetrics: ScanBenchmarkReliabilityMetrics,
    localizationMetric: ScanBenchmarkUnsupportedMetric,
    amountMetric: ScanBenchmarkUnsupportedMetric
  ) {
    self.id = id
    self.scenarioTags = scenarioTags
    self.expectedIngredientIds = expectedIngredientIds
    self.runs = runs
    self.status = status
    self.invalidReason = invalidReason
    self.detectionMetrics = detectionMetrics
    self.correctionMetrics = correctionMetrics
    self.calibrationMetrics = calibrationMetrics
    self.ocrMetrics = ocrMetrics
    self.latencyMetrics = latencyMetrics
    self.reliabilityMetrics = reliabilityMetrics
    self.localizationMetric = localizationMetric
    self.amountMetric = amountMetric
  }
}

public struct ScanBenchmarkReportSummary: Sendable, Codable, Equatable {
  public let imageCount: Int
  public let passedImageCount: Int
  public let regressedImageCount: Int
  public let invalidImageCount: Int
  public let overallDetectionF1: Double?
  public let overallMinimumReliabilityJaccard: Double?
  public let overallMedianElapsedMs: Int?

  public init(
    imageCount: Int,
    passedImageCount: Int,
    regressedImageCount: Int,
    invalidImageCount: Int,
    overallDetectionF1: Double?,
    overallMinimumReliabilityJaccard: Double?,
    overallMedianElapsedMs: Int?
  ) {
    self.imageCount = imageCount
    self.passedImageCount = passedImageCount
    self.regressedImageCount = regressedImageCount
    self.invalidImageCount = invalidImageCount
    self.overallDetectionF1 = overallDetectionF1
    self.overallMinimumReliabilityJaccard = overallMinimumReliabilityJaccard
    self.overallMedianElapsedMs = overallMedianElapsedMs
  }
}

public struct ScanBenchmarkReport: Sendable, Codable, Equatable {
  public let createdAtISO8601: String
  public let iterations: Int
  public let gates: ScanBenchmarkGates
  public let status: ScanBenchmarkStatus
  public let invalidReason: String?
  public let summary: ScanBenchmarkReportSummary
  public let images: [ScanBenchmarkImageReport]

  public init(
    createdAtISO8601: String,
    iterations: Int,
    gates: ScanBenchmarkGates,
    status: ScanBenchmarkStatus,
    invalidReason: String?,
    summary: ScanBenchmarkReportSummary,
    images: [ScanBenchmarkImageReport]
  ) {
    self.createdAtISO8601 = createdAtISO8601
    self.iterations = iterations
    self.gates = gates
    self.status = status
    self.invalidReason = invalidReason
    self.summary = summary
    self.images = images
  }
}
