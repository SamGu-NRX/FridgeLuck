import FLFeatureLogic
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
          Text("Scan quality benchmarks use the real scan pipeline on a labeled image corpus.")
          Text("Unsupported today: ingredient segmentation and image-derived quantity detection.")
          Text("Run records include source, provenance, bucket counts, and per-item evidence.")
        }

        Section("Scan Quality Benchmark") {
          Button {
            Task { await runScanQualityBenchmark() }
          } label: {
            if isRunningBenchmark {
              Label("Running benchmark...", systemImage: "hourglass")
            } else {
              Label("Run Scan Quality Benchmark", systemImage: "speedometer")
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

  private func runScanQualityBenchmark() async {
    guard !isRunningBenchmark else { return }
    isRunningBenchmark = true
    defer { isRunningBenchmark = false }

    do {
      let corpus = try ScanBenchmarkRunner.defaultCorpus()
      let report = try await ScanBenchmarkRunner.run(
        corpus: corpus,
        visionService: deps.visionService
      )
      let outputURL = ScanRunStore.benchmarkOutputURL()
      try ScanBenchmarkRunner.writeReport(report, to: outputURL)
      benchmarkStatus = benchmarkSummaryText(report: report, outputURL: outputURL)
    } catch {
      benchmarkStatus = "Benchmark failed to save: \(error.localizedDescription)"
    }

    await loadRuns()
  }

  private func benchmarkSummaryText(report: ScanBenchmarkReport, outputURL: URL) -> String {
    let detectionF1Text =
      report.summary.overallDetectionF1.map {
        String(format: "%.3f", $0)
      } ?? "n/a"
    let reliabilityText =
      report.summary.overallMinimumReliabilityJaccard.map {
        String(format: "%.3f", $0)
      } ?? "n/a"
    let latencyText = report.summary.overallMedianElapsedMs.map(String.init) ?? "n/a"

    let statusText: String
    switch report.status {
    case .passed:
      statusText = "passed"
    case .regressed:
      statusText = "regressed"
    case .invalid:
      statusText = "invalid"
    }

    let unsupported =
      report.images.first.map {
        [$0.localizationMetric.name, $0.amountMetric.name].joined(separator: ", ")
      } ?? "vision_localization, image_amount_detection"

    return
      "Saved benchmark to \(outputURL.path). status \(statusText). F1 \(detectionF1Text), minJaccard \(reliabilityText), median \(latencyText)ms. Unsupported: \(unsupported)."
  }
}
