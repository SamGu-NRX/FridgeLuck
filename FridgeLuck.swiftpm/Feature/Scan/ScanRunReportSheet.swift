import Foundation
import SwiftUI

struct ScanRunReportSheet: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  @State private var runs: [ScanRunRecord] = []
  @State private var isLoading = false
  @State private var isRunningBenchmark = false
  @State private var benchmarkStatus: String?

  var body: some View {
    NavigationStack {
      List {
        Section("Verification Notes") {
          Text("Confidence scores are routing signals, not calibrated probabilities.")
          Text("Run records include source, provenance, bucket counts, and per-item evidence.")
        }

        Section("Benchmark") {
          Button {
            Task { await runBundledDemoBenchmark() }
          } label: {
            if isRunningBenchmark {
              Label("Running benchmark...", systemImage: "hourglass")
            } else {
              Label("Run 5x Bundled Demo Benchmark", systemImage: "speedometer")
            }
          }
          .disabled(isRunningBenchmark)

          if let benchmarkStatus {
            Text(benchmarkStatus)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        Section("Recent Scan Runs") {
          if isLoading && runs.isEmpty {
            ProgressView("Loading runs...")
          } else if runs.isEmpty {
            Text("No runs yet. Capture a live photo or run demo scan to populate this list.")
          } else {
            ForEach(runs) { run in
              VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                HStack {
                  Text(run.runMode.rawValue.capitalized)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.textPrimary)
                  Spacer()
                  Text(run.createdAt, style: .time)
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.textSecondary)
                }

                Text(
                  "Provenance: \(run.provenance.rawValue) · Sources: \(run.inputSources.map(\.rawValue).joined(separator: ", "))"
                )
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)

                Text(
                  "Elapsed \(run.elapsedMs)ms · Auto \(run.bucketCounts.auto) · Confirm \(run.bucketCounts.confirm) · Possible \(run.bucketCounts.possible)"
                )
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)

                if !run.passErrors.isEmpty {
                  Text("Pass errors: \(run.passErrors.count)")
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.accent)
                }

                if !run.detections.isEmpty {
                  Text(
                    run.detections.prefix(6).map {
                      "\($0.label) (\(Int(($0.confidenceScore * 100).rounded()))%)"
                    }
                    .joined(separator: ", ")
                  )
                  .font(AppTheme.Typography.bodySmall)
                  .foregroundStyle(AppTheme.textSecondary)
                  .lineLimit(2)
                }
              }
              .padding(.vertical, AppTheme.Space.xxxs)
            }
          }
        }
      }
      .navigationTitle("Scan Run Reports")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await loadRuns() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .task {
      await loadRuns()
    }
  }

  private func loadRuns() async {
    isLoading = true
    runs = await deps.scanRunStore.recent(limit: 40)
    isLoading = false
  }

  private func runBundledDemoBenchmark() async {
    guard !isRunningBenchmark else { return }
    isRunningBenchmark = true
    defer { isRunningBenchmark = false }

    guard
      let image = DemoScanService.loadDemoImage(),
      let cgImage = image.cgImage
    else {
      benchmarkStatus = "Bundled demo image not found."
      return
    }

    let iterations = ScanDemoGate.benchmarkIterations
    var idSets: [Set<Int64>] = []
    var elapsed: [Int] = []
    var bucketRuns: [ScanBucketCounts] = []

    for index in 0..<iterations {
      let result = try? await deps.visionService.scan(
        inputs: [ScanInput(image: cgImage, source: .demo, captureIndex: index)]
      )
      let ids = Set((result?.detections ?? []).map(\.ingredientId))
      idSets.append(ids)
      elapsed.append(result?.diagnostics.elapsedMs ?? 0)
      bucketRuns.append(
        result?.diagnostics.bucketCounts ?? ScanBucketCounts(auto: 0, confirm: 0, possible: 0))
    }

    let baseline = idSets.first ?? []
    let jaccards = idSets.map { jaccard(baseline, $0) }
    let meanJaccard = jaccards.isEmpty ? 0 : jaccards.reduce(0, +) / Double(jaccards.count)
    let minJaccard = jaccards.min() ?? 0
    let sortedElapsed = elapsed.sorted()
    let medianElapsed = sortedElapsed.isEmpty ? 0 : sortedElapsed[sortedElapsed.count / 2]

    struct BenchmarkSummary: Codable {
      let generatedAtISO8601: String
      let iterations: Int
      let minJaccard: Double
      let meanJaccard: Double
      let medianElapsedMs: Int
      let bucketRuns: [ScanBucketCounts]
    }

    let summary = BenchmarkSummary(
      generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
      iterations: iterations,
      minJaccard: minJaccard,
      meanJaccard: meanJaccard,
      medianElapsedMs: medianElapsed,
      bucketRuns: bucketRuns
    )

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(summary)
      let outputURL = ScanRunStore.benchmarkOutputURL()
      try data.write(to: outputURL, options: .atomic)
      benchmarkStatus =
        "Saved benchmark to \(outputURL.path). minJaccard \(String(format: "%.3f", minJaccard)), mean \(String(format: "%.3f", meanJaccard)), median \(medianElapsed)ms."
    } catch {
      benchmarkStatus = "Benchmark failed to save: \(error.localizedDescription)"
    }

    await loadRuns()
  }

  private func jaccard(_ a: Set<Int64>, _ b: Set<Int64>) -> Double {
    if a.isEmpty, b.isEmpty { return 1.0 }
    let union = a.union(b).count
    guard union > 0 else { return 0 }
    return Double(a.intersection(b).count) / Double(union)
  }
}
