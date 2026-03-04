import Foundation
import ImageIO

struct ScanBenchmarkImage: Sendable, Codable {
  let id: String
  let path: String
  let source: ScanInputSource
}

struct ScanBenchmarkManifest: Sendable, Codable {
  let iterations: Int
  let images: [ScanBenchmarkImage]

  static func demoDefault() -> ScanBenchmarkManifest {
    ScanBenchmarkManifest(
      iterations: ScanDemoGate.benchmarkIterations,
      images: [
        ScanBenchmarkImage(id: "fridge_1", path: "example_fridge_1.png", source: .benchmark),
        ScanBenchmarkImage(id: "fridge_2", path: "example_fridge_2.png", source: .benchmark),
        ScanBenchmarkImage(id: "fridge_3", path: "example_fridge_3.png", source: .benchmark),
        ScanBenchmarkImage(
          id: "bundled_demo_image",
          path: "FridgeLuck.swiftpm/Resources/demo/garlic_fried_rice.jpg",
          source: .demo
        ),
      ]
    )
  }
}

struct ScanBenchmarkRunResult: Sendable, Codable {
  let iteration: Int
  let ingredientIds: [Int64]
  let elapsedMs: Int
  let bucketCounts: ScanBucketCounts
}

struct ScanBenchmarkImageReport: Sendable, Codable {
  let id: String
  let path: String
  let runs: [ScanBenchmarkRunResult]
  let meanJaccardVsFirst: Double
  let minJaccardVsFirst: Double
  let medianElapsedMs: Int
}

struct ScanBenchmarkReport: Sendable, Codable {
  let createdAtISO8601: String
  let iterations: Int
  let targetThreeShotMedianMs: Int
  let requiredJaccard: Double
  let reports: [ScanBenchmarkImageReport]
}

enum ScanBenchmarkRunner {
  static func run(
    manifest: ScanBenchmarkManifest,
    visionService: VisionService,
    baseDirectory: URL
  ) async -> ScanBenchmarkReport {
    var reports: [ScanBenchmarkImageReport] = []

    for image in manifest.images {
      let imageURL = baseDirectory.appendingPathComponent(image.path)
      guard let cgImage = loadCGImage(at: imageURL) else {
        continue
      }

      var runResults: [ScanBenchmarkRunResult] = []
      var jaccards: [Double] = []
      var baseline: Set<Int64>?

      for iteration in 0..<max(1, manifest.iterations) {
        let startedAt = Date()
        let result = try? await visionService.scan(
          inputs: [
            ScanInput(image: cgImage, source: image.source, captureIndex: 0)
          ]
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let detections = result?.detections ?? []
        let ids = detections.map(\.ingredientId).sorted()
        let idSet = Set(ids)

        if let baseline {
          jaccards.append(jaccard(a: baseline, b: idSet))
        } else {
          baseline = idSet
          jaccards.append(1.0)
        }

        let bucketCounts =
          result?.diagnostics.bucketCounts
          ?? ScanBucketCounts(auto: 0, confirm: 0, possible: 0)

        runResults.append(
          ScanBenchmarkRunResult(
            iteration: iteration,
            ingredientIds: ids,
            elapsedMs: elapsedMs,
            bucketCounts: bucketCounts
          )
        )
      }

      let elapsedList = runResults.map(\.elapsedMs).sorted()
      let medianElapsedMs = elapsedList.isEmpty ? 0 : elapsedList[elapsedList.count / 2]
      let meanJaccard = jaccards.isEmpty ? 0 : jaccards.reduce(0, +) / Double(jaccards.count)
      let minJaccard = jaccards.min() ?? 0

      reports.append(
        ScanBenchmarkImageReport(
          id: image.id,
          path: image.path,
          runs: runResults,
          meanJaccardVsFirst: meanJaccard,
          minJaccardVsFirst: minJaccard,
          medianElapsedMs: medianElapsedMs
        )
      )
    }

    return ScanBenchmarkReport(
      createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
      iterations: manifest.iterations,
      targetThreeShotMedianMs: ScanDemoGate.targetThreeShotMedianMs,
      requiredJaccard: ScanDemoGate.minJaccardForStability,
      reports: reports
    )
  }

  static func writeReport(_ report: ScanBenchmarkReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: url, options: .atomic)
  }

  private static func loadCGImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func jaccard(a: Set<Int64>, b: Set<Int64>) -> Double {
    if a.isEmpty, b.isEmpty { return 1.0 }
    let intersection = a.intersection(b).count
    let union = a.union(b).count
    guard union > 0 else { return 0 }
    return Double(intersection) / Double(union)
  }
}
