import Foundation
import StoragePerfCore

// StoragePerf CLI — runs the full sweep (seeding, repository reads, plans,
// experiments) and writes a digest-signed canonical JSON report bound to an
// execution-source manifest. Verification regenerates every summary from the
// frozen measurements before anything is written.
//
// Usage:
//   StoragePerf [--out PATH] [--profiles month,year,five_year]
//               [--scales 1,2,4,8,16] [--iterations N] [--warmup N]
//               [--no-experiments] [--seed N]
//   StoragePerf --verify PATH   (re-verify a written report against sources)
//
// Exit codes: 0 = verified report written (or --verify passed);
// 1 = sweep, verification, or source-binding failure.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
  exit(1)
}

struct CLIOptions {
  var seed: UInt64 = 20261010
  var profiles: [WorkloadProfile] = WorkloadProfile.allCases
  var scales: [Int] = workloadScales
  var warmup = 3
  var iterations = 15
  var experiments = true
  var outPath = "storage-perf-results/summary.json"
}

func parseArgs(_ args: [String]) -> CLIOptions {
  var options = CLIOptions()
  var index = 0
  while index < args.count {
    let key = args[index]
    func value() -> String {
      index += 1
      guard index < args.count else { fail("missing value for \(key)") }
      return args[index]
    }
    switch key {
    case "--out":
      options.outPath = value()
    case "--profiles":
      let parsed = value().split(separator: ",").compactMap { part in
        WorkloadProfile.allCases.first { $0.label == part }
      }
      guard !parsed.isEmpty else { fail("no valid profiles; labels: \(WorkloadProfile.allCases.map(\.label))") }
      options.profiles = parsed
    case "--scales":
      let parsed = value().split(separator: ",").compactMap { Int($0) }
      guard !parsed.isEmpty else { fail("no valid scales") }
      options.scales = parsed
    case "--iterations":
      guard let parsed = Int(value()), parsed > 0 else { fail("--iterations needs a positive integer") }
      options.iterations = parsed
    case "--warmup":
      guard let parsed = Int(value()), parsed >= 0 else { fail("--warmup needs a non-negative integer") }
      options.warmup = parsed
    case "--seed":
      guard let parsed = UInt64(value()) else { fail("--seed needs an unsigned integer") }
      options.seed = parsed
    case "--no-experiments":
      options.experiments = false
    default:
      fail("unknown argument \(key)")
    }
    index += 1
  }
  return options
}

let argsList = Array(CommandLine.arguments.dropFirst())

do {
  // --verify PATH: re-verify a written report (digest, summary regeneration,
  // source-manifest binding) without running a sweep. Checked before
  // parseArgs, which only knows the sweep options.
  if argsList.first == "--verify" {
    guard argsList.count == 2 else { fail("--verify takes exactly one report path") }
    let text = try String(contentsOfFile: argsList[1], encoding: .utf8)
    let digest = try ReportVerifier.verify(text: text, sourceRoot: SourceManifest.packageRoot())
    print("verified \(argsList[1])")
    print("digest \(digest)")
    exit(0)
  }

  let cli = parseArgs(argsList)
  let runnerOptions = RunnerOptions(
    seed: cli.seed, profiles: cli.profiles, scales: cli.scales,
    warmup: cli.warmup, iterations: cli.iterations, experiments: cli.experiments)

  let summary = try Runner.runSweep(options: runnerOptions)
  let report = Runner.renderReport(withDigest: summary)
  // The tool never ships a report it cannot itself verify — including the
  // binding between the report and the sources that produced it.
  let digest = try ReportVerifier.verify(
    text: report, sourceRoot: SourceManifest.packageRoot())

  let url = URL(fileURLWithPath: cli.outPath)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try report.data(using: .utf8)!.write(to: url)

  print("wrote \(cli.outPath)")
  print("digest \(digest)")
  exit(0)
} catch {
  fail("\(error)")
}
