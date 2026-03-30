import Foundation

public enum ScanBenchmarkScorer {
  private static let localizationUnsupportedMetric = ScanBenchmarkUnsupportedMetric(
    name: "vision_localization",
    status: .notSupported,
    reason: "Vision detections do not expose ingredient bounding boxes in the current pipeline."
  )
  private static let amountUnsupportedMetric = ScanBenchmarkUnsupportedMetric(
    name: "image_amount_detection",
    status: .notSupported,
    reason: "Image-derived quantity estimation is not implemented. Current grams are heuristics."
  )

  public static func evaluateImage(
    corpusEntry: ScanBenchmarkCorpusEntry,
    runs: [ScanBenchmarkRunObservation],
    gates: ScanBenchmarkGates
  ) -> ScanBenchmarkImageReport {
    let expectedIds = Set(corpusEntry.expectedIngredientIds)
    let runReports = runs.map { makeRunReport(run: $0, expectedIds: expectedIds) }
    let validRuns = zip(runs, runReports).filter { $0.1.valid }
    let invalidRunCount = runReports.filter { !$0.valid }.count

    if validRuns.isEmpty {
      return makeImageReport(
        corpusEntry: corpusEntry,
        runs: runReports,
        status: .invalid,
        invalidReason: invalidReason(from: runReports) ?? "No valid benchmark runs completed.",
        detectionMetrics: ScanBenchmarkDetectionMetrics(
          status: .failed,
          precision: nil,
          recall: nil,
          f1: nil,
          expectedIngredientCount: expectedIds.count,
          averageDetectedCount: nil
        ),
        correctionMetrics: ScanBenchmarkCorrectionMetrics(
          status: .failed,
          topPredictionAcceptanceRate: nil,
          alternativeCoverageRate: nil,
          missedExpectationCount: expectedIds.count
        ),
        calibrationMetrics: defaultCalibrationMetrics(),
        ocrMetrics: notSupportedOCRMetrics(
          expectedNutrition: corpusEntry.expectedNutrition,
          fallbackStatus: .failed
        ),
        latencyMetrics: ScanBenchmarkLatencyMetrics(
          status: .failed,
          medianElapsedMs: nil,
          p90ElapsedMs: nil,
          targetMedianElapsedMs: gates.targetMedianElapsedMs
        ),
        reliabilityMetrics: ScanBenchmarkReliabilityMetrics(
          status: .failed,
          validRunCount: 0,
          invalidRunCount: invalidRunCount,
          meanJaccardVsFirstValid: nil,
          minJaccardVsFirstValid: nil,
          requiredJaccard: gates.minimumReliabilityJaccard
        ),
      )
    }

    let validObservations = validRuns.map(\.0)
    let validReports = validRuns.map(\.1)

    let detectionMetrics = detectionMetrics(
      expectedIds: expectedIds,
      observations: validObservations
    )
    let correctionMetrics = correctionMetrics(
      expectedIds: expectedIds,
      observations: validObservations
    )
    let calibrationMetrics = calibrationMetrics(
      expectedIds: expectedIds,
      observations: validObservations
    )
    let ocrMetrics = ocrMetrics(
      expectedNutrition: corpusEntry.expectedNutrition,
      observations: validObservations
    )
    let latencyMetrics = latencyMetrics(
      observations: validObservations,
      targetMedianElapsedMs: gates.targetMedianElapsedMs
    )
    let reliabilityMetrics = reliabilityMetrics(
      reports: validReports,
      requiredJaccard: gates.minimumReliabilityJaccard,
      invalidRunCount: invalidRunCount
    )

    let status: ScanBenchmarkStatus
    if invalidRunCount > 0 {
      status = .invalid
    } else if isRegressed(
      detectionMetrics: detectionMetrics,
      correctionMetrics: correctionMetrics,
      ocrMetrics: ocrMetrics,
      latencyMetrics: latencyMetrics,
      reliabilityMetrics: reliabilityMetrics,
      gates: gates
    ) {
      status = .regressed
    } else {
      status = .passed
    }

    return makeImageReport(
      corpusEntry: corpusEntry,
      runs: runReports,
      status: status,
      invalidReason: invalidRunCount > 0 ? invalidReason(from: runReports) : nil,
      detectionMetrics: detectionMetrics,
      correctionMetrics: correctionMetrics,
      calibrationMetrics: calibrationMetrics,
      ocrMetrics: ocrMetrics,
      latencyMetrics: latencyMetrics,
      reliabilityMetrics: reliabilityMetrics
    )
  }

  public static func makeReport(
    corpus: ScanBenchmarkCorpus,
    imageReports: [ScanBenchmarkImageReport],
    createdAt: Date = Date()
  ) -> ScanBenchmarkReport {
    let invalidImageCount = imageReports.filter { $0.status == .invalid }.count
    let regressedImageCount = imageReports.filter { $0.status == .regressed }.count
    let passedImageCount = imageReports.filter { $0.status == .passed }.count

    let overallStatus: ScanBenchmarkStatus
    let invalidReason: String?
    if imageReports.isEmpty {
      overallStatus = .invalid
      invalidReason = "No benchmark images were evaluated."
    } else if invalidImageCount > 0 {
      overallStatus = .invalid
      invalidReason = imageReports.first(where: { $0.status == .invalid })?.invalidReason
    } else if regressedImageCount > 0 {
      overallStatus = .regressed
      invalidReason = nil
    } else {
      overallStatus = .passed
      invalidReason = nil
    }

    let measuredF1Values = imageReports.compactMap(\.detectionMetrics.f1)
    let measuredMinJaccard = imageReports.compactMap(\.reliabilityMetrics.minJaccardVsFirstValid)
    let measuredLatency = imageReports.compactMap(\.latencyMetrics.medianElapsedMs)

    let summary = ScanBenchmarkReportSummary(
      imageCount: imageReports.count,
      passedImageCount: passedImageCount,
      regressedImageCount: regressedImageCount,
      invalidImageCount: invalidImageCount,
      overallDetectionF1: mean(of: measuredF1Values),
      overallMinimumReliabilityJaccard: measuredMinJaccard.min(),
      overallMedianElapsedMs: median(of: measuredLatency)
    )

    let createdAtISO8601 = ISO8601DateFormatter().string(from: createdAt)
    return ScanBenchmarkReport(
      createdAtISO8601: createdAtISO8601,
      iterations: corpus.iterations,
      gates: corpus.gates,
      status: overallStatus,
      invalidReason: invalidReason,
      summary: summary,
      images: imageReports
    )
  }

  private static func makeImageReport(
    corpusEntry: ScanBenchmarkCorpusEntry,
    runs: [ScanBenchmarkRunReport],
    status: ScanBenchmarkStatus,
    invalidReason: String?,
    detectionMetrics: ScanBenchmarkDetectionMetrics,
    correctionMetrics: ScanBenchmarkCorrectionMetrics,
    calibrationMetrics: [ScanBenchmarkCalibrationMetric],
    ocrMetrics: ScanBenchmarkOCRMetrics,
    latencyMetrics: ScanBenchmarkLatencyMetrics,
    reliabilityMetrics: ScanBenchmarkReliabilityMetrics
  ) -> ScanBenchmarkImageReport {
    ScanBenchmarkImageReport(
      id: corpusEntry.id,
      scenarioTags: corpusEntry.scenarioTags,
      expectedIngredientIds: corpusEntry.expectedIngredientIds,
      runs: runs,
      status: status,
      invalidReason: invalidReason,
      detectionMetrics: detectionMetrics,
      correctionMetrics: correctionMetrics,
      calibrationMetrics: calibrationMetrics,
      ocrMetrics: ocrMetrics,
      latencyMetrics: latencyMetrics,
      reliabilityMetrics: reliabilityMetrics,
      localizationMetric: localizationUnsupportedMetric,
      amountMetric: amountUnsupportedMetric
    )
  }

  private static func makeRunReport(
    run: ScanBenchmarkRunObservation,
    expectedIds: Set<Int64>
  ) -> ScanBenchmarkRunReport {
    let ingredientIds = run.detections.map(\.ingredientId).sorted()
    let alternativeIds = Array(
      Set(run.detections.flatMap(\.alternativeIngredientIds))
    ).sorted()

    let invalidReason: String?
    if let errorDescription = run.errorDescription, !errorDescription.isEmpty {
      invalidReason = "Scan error: \(errorDescription)"
    } else if !run.passErrors.isEmpty {
      invalidReason = "Scan reported \(run.passErrors.count) pass error(s)."
    } else if !expectedIds.isEmpty, ingredientIds.isEmpty {
      invalidReason = "Expected non-empty detections but scan returned none."
    } else {
      invalidReason = nil
    }

    return ScanBenchmarkRunReport(
      iteration: run.iteration,
      ingredientIds: ingredientIds,
      alternativeIngredientIds: alternativeIds,
      elapsedMs: run.elapsedMs,
      valid: invalidReason == nil,
      invalidReason: invalidReason,
      errorDescription: run.errorDescription,
      passErrors: run.passErrors
    )
  }

  private static func detectionMetrics(
    expectedIds: Set<Int64>,
    observations: [ScanBenchmarkRunObservation]
  ) -> ScanBenchmarkDetectionMetrics {
    guard !observations.isEmpty else {
      return ScanBenchmarkDetectionMetrics(
        status: .failed,
        precision: nil,
        recall: nil,
        f1: nil,
        expectedIngredientCount: expectedIds.count,
        averageDetectedCount: nil
      )
    }

    let perRun = observations.map { observation -> (Double, Double, Double, Int) in
      let observedIds = Set(observation.detections.map(\.ingredientId))
      let truePositives = observedIds.intersection(expectedIds).count
      let precision = observedIds.isEmpty ? 0 : Double(truePositives) / Double(observedIds.count)
      let recall = expectedIds.isEmpty ? 1 : Double(truePositives) / Double(expectedIds.count)
      let f1 = harmonicMean(precision, recall)
      return (precision, recall, f1, observedIds.count)
    }

    return ScanBenchmarkDetectionMetrics(
      status: .measured,
      precision: mean(of: perRun.map(\.0)),
      recall: mean(of: perRun.map(\.1)),
      f1: mean(of: perRun.map(\.2)),
      expectedIngredientCount: expectedIds.count,
      averageDetectedCount: mean(of: perRun.map { Double($0.3) })
    )
  }

  private static func correctionMetrics(
    expectedIds: Set<Int64>,
    observations: [ScanBenchmarkRunObservation]
  ) -> ScanBenchmarkCorrectionMetrics {
    guard !observations.isEmpty else {
      return ScanBenchmarkCorrectionMetrics(
        status: .failed,
        topPredictionAcceptanceRate: nil,
        alternativeCoverageRate: nil,
        missedExpectationCount: expectedIds.count
      )
    }

    var topAcceptanceSamples: [Double] = []
    var alternativeCoverageSamples: [Double] = []
    var totalMissedCount = 0

    for observation in observations {
      let observedIds = Set(observation.detections.map(\.ingredientId))
      let matchedTop = observation.detections.filter { expectedIds.contains($0.ingredientId) }.count
      let topAcceptance =
        observation.detections.isEmpty
        ? 0
        : Double(matchedTop) / Double(observation.detections.count)
      topAcceptanceSamples.append(topAcceptance)

      let missedExpected = expectedIds.subtracting(observedIds)
      totalMissedCount += missedExpected.count

      guard !missedExpected.isEmpty else { continue }

      let coveredByAlternatives = Set(
        observation.detections.flatMap(\.alternativeIngredientIds)
      ).intersection(missedExpected)
      alternativeCoverageSamples.append(
        Double(coveredByAlternatives.count) / Double(missedExpected.count)
      )
    }

    let alternativeStatus: ScanBenchmarkMetricStatus =
      alternativeCoverageSamples.isEmpty ? .notSupported : .measured

    return ScanBenchmarkCorrectionMetrics(
      status: alternativeStatus == .measured ? .measured : .notSupported,
      topPredictionAcceptanceRate: mean(of: topAcceptanceSamples),
      alternativeCoverageRate: mean(of: alternativeCoverageSamples),
      missedExpectationCount: totalMissedCount
    )
  }

  private static func calibrationMetrics(
    expectedIds: Set<Int64>,
    observations: [ScanBenchmarkRunObservation]
  ) -> [ScanBenchmarkCalibrationMetric] {
    let buckets: [ScanBenchmarkDetectionBucket] = [.auto, .confirm, .possible]
    return buckets.map { bucket in
      let detections = observations.flatMap(\.detections).filter { $0.bucket == bucket }
      let matchedCount = detections.filter { expectedIds.contains($0.ingredientId) }.count
      let sampleCount = detections.count

      return ScanBenchmarkCalibrationMetric(
        bucket: bucket,
        status: sampleCount > 0 ? .measured : .notSupported,
        sampleCount: sampleCount,
        matchedCount: matchedCount,
        precision: sampleCount > 0 ? Double(matchedCount) / Double(sampleCount) : nil
      )
    }
  }

  private static func ocrMetrics(
    expectedNutrition: ScanBenchmarkExpectedNutrition?,
    observations: [ScanBenchmarkRunObservation]
  ) -> ScanBenchmarkOCRMetrics {
    guard let expectedNutrition else {
      return notSupportedOCRMetrics(
        expectedNutrition: nil,
        fallbackStatus: .notSupported
      )
    }

    guard !observations.isEmpty else {
      return notSupportedOCRMetrics(
        expectedNutrition: expectedNutrition,
        fallbackStatus: .failed
      )
    }

    let parsedRuns = observations.map(\.nutrition)
    let parseSuccessRate = Double(parsedRuns.compactMap { $0 }.count) / Double(observations.count)

    let caloriesAccuracy = averageNutritionAccuracy(
      expected: expectedNutrition.caloriesPerServing,
      observed: parsedRuns.map(\.?.caloriesPerServing),
      comparator: numericAccuracy
    )
    let servingSizeAccuracy = averageNutritionAccuracy(
      expected: expectedNutrition.servingSize,
      observed: parsedRuns.map(\.?.servingSize),
      comparator: stringAccuracy
    )
    let servingsPerContainerAccuracy = averageNutritionAccuracy(
      expected: expectedNutrition.servingsPerContainer,
      observed: parsedRuns.map(\.?.servingsPerContainer),
      comparator: numericAccuracy
    )

    return ScanBenchmarkOCRMetrics(
      status: .measured,
      parseSuccessRate: parseSuccessRate,
      caloriesAccuracy: caloriesAccuracy,
      servingSizeAccuracy: servingSizeAccuracy,
      servingsPerContainerAccuracy: servingsPerContainerAccuracy
    )
  }

  private static func latencyMetrics(
    observations: [ScanBenchmarkRunObservation],
    targetMedianElapsedMs: Int
  ) -> ScanBenchmarkLatencyMetrics {
    let elapsedValues = observations.map(\.elapsedMs)
    return ScanBenchmarkLatencyMetrics(
      status: elapsedValues.isEmpty ? .failed : .measured,
      medianElapsedMs: median(of: elapsedValues),
      p90ElapsedMs: percentile90(of: elapsedValues),
      targetMedianElapsedMs: targetMedianElapsedMs
    )
  }

  private static func reliabilityMetrics(
    reports: [ScanBenchmarkRunReport],
    requiredJaccard: Double,
    invalidRunCount: Int
  ) -> ScanBenchmarkReliabilityMetrics {
    let validIdSets = reports.map { Set($0.ingredientIds) }

    guard !validIdSets.isEmpty else {
      return ScanBenchmarkReliabilityMetrics(
        status: .failed,
        validRunCount: 0,
        invalidRunCount: invalidRunCount,
        meanJaccardVsFirstValid: nil,
        minJaccardVsFirstValid: nil,
        requiredJaccard: requiredJaccard
      )
    }

    let baseline = validIdSets[0]
    let jaccards = validIdSets.map { jaccard(a: baseline, b: $0) }

    return ScanBenchmarkReliabilityMetrics(
      status: .measured,
      validRunCount: reports.count,
      invalidRunCount: invalidRunCount,
      meanJaccardVsFirstValid: mean(of: jaccards),
      minJaccardVsFirstValid: jaccards.min(),
      requiredJaccard: requiredJaccard
    )
  }

  private static func isRegressed(
    detectionMetrics: ScanBenchmarkDetectionMetrics,
    correctionMetrics: ScanBenchmarkCorrectionMetrics,
    ocrMetrics: ScanBenchmarkOCRMetrics,
    latencyMetrics: ScanBenchmarkLatencyMetrics,
    reliabilityMetrics: ScanBenchmarkReliabilityMetrics,
    gates: ScanBenchmarkGates
  ) -> Bool {
    if let detectionF1 = detectionMetrics.f1, detectionF1 < gates.minimumDetectionF1 {
      return true
    }

    if correctionMetrics.status == .measured,
      let coverage = correctionMetrics.alternativeCoverageRate,
      correctionMetrics.missedExpectationCount > 0,
      coverage < gates.minimumCorrectionCoverage
    {
      return true
    }

    if ocrMetrics.status == .measured {
      let fieldScores = [
        ocrMetrics.caloriesAccuracy,
        ocrMetrics.servingSizeAccuracy,
        ocrMetrics.servingsPerContainerAccuracy,
      ].compactMap { $0 }
      if let averageFieldScore = mean(of: fieldScores),
        averageFieldScore < gates.minimumOCRFieldAccuracy
      {
        return true
      }
    }

    if let medianElapsedMs = latencyMetrics.medianElapsedMs,
      medianElapsedMs > gates.targetMedianElapsedMs
    {
      return true
    }

    if let minJaccard = reliabilityMetrics.minJaccardVsFirstValid,
      minJaccard < gates.minimumReliabilityJaccard
    {
      return true
    }

    return false
  }

  private static func invalidReason(from runs: [ScanBenchmarkRunReport]) -> String? {
    runs.first(where: { !$0.valid })?.invalidReason
  }

  private static func defaultCalibrationMetrics() -> [ScanBenchmarkCalibrationMetric] {
    [.auto, .confirm, .possible].map {
      ScanBenchmarkCalibrationMetric(
        bucket: $0,
        status: .notSupported,
        sampleCount: 0,
        matchedCount: 0,
        precision: nil
      )
    }
  }

  private static func notSupportedOCRMetrics(
    expectedNutrition: ScanBenchmarkExpectedNutrition?,
    fallbackStatus: ScanBenchmarkMetricStatus
  ) -> ScanBenchmarkOCRMetrics {
    ScanBenchmarkOCRMetrics(
      status: expectedNutrition == nil ? .notSupported : fallbackStatus,
      parseSuccessRate: nil,
      caloriesAccuracy: nil,
      servingSizeAccuracy: nil,
      servingsPerContainerAccuracy: nil
    )
  }

  private static func harmonicMean(_ lhs: Double, _ rhs: Double) -> Double {
    guard lhs > 0 || rhs > 0 else { return 0 }
    return (2 * lhs * rhs) / max(lhs + rhs, 0.0001)
  }

  private static func numericAccuracy(expected: Double?, observed: Double?) -> Double? {
    guard let expected else { return nil }
    guard let observed else { return 0 }
    let difference = abs(expected - observed)
    if difference <= 0.5 { return 1 }
    let relative = difference / max(abs(expected), 1)
    return max(0, 1 - relative)
  }

  private static func stringAccuracy(expected: String?, observed: String?) -> Double? {
    guard let expected else { return nil }
    guard let observed else { return 0 }
    return normalized(expected) == normalized(observed) ? 1 : 0
  }

  private static func averageNutritionAccuracy<T>(
    expected: T?,
    observed: [T?],
    comparator: (T?, T?) -> Double?
  ) -> Double? {
    let values = observed.compactMap { comparator(expected, $0) }
    return mean(of: values)
  }

  private static func normalized(_ value: String) -> String {
    value
      .lowercased()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func jaccard(a: Set<Int64>, b: Set<Int64>) -> Double {
    if a.isEmpty || b.isEmpty { return 0 }
    let union = a.union(b).count
    guard union > 0 else { return 0 }
    return Double(a.intersection(b).count) / Double(union)
  }

  private static func mean(of values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  private static func median(of values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }

  private static func percentile90(of values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * 0.9).rounded(.up))
    return sorted[min(index, sorted.count - 1)]
  }
}
