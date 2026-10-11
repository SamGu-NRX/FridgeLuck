import Foundation
import FLTaste
import FLTasteEvalCore
import FLTasteSim

// fltaste-eval: the suite-B campaign driver.
//
//   fltaste-eval --config smoke --out out/
//   fltaste-eval --config full  --out out/            (run under tmux)
//   fltaste-eval --config custom --households 2000 --seeds 8 --out out/
//
// Checkpoints land at <out>/checkpoints/seed-<s>/arm-<a>.json and are
// skipped on resume; final outputs: results.json, gate.json, arms.json.

struct RunManifest: Codable {
    var config: CampaignConfig
    var arms: [ArmRosterEntry]
    var startedAt: String
    var hostname: String
    var swiftVersion: String
    var corpusPath: String
    var corpusRecipeCount: Int
    var note: String
}

/// Thread-safe accumulator box: worker threads fold household metrics in
/// under a lock; the caller reads the pooled result when they all finish.
final class LockedAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = ArmSeedAccumulator()

    func add(_ metrics: HouseholdMetrics, regime: String) {
        lock.lock()
        defer { lock.unlock() }
        accumulator.add(metrics, regime: regime)
    }

    func value() -> ArmSeedAccumulator {
        lock.lock()
        defer { lock.unlock() }
        return accumulator
    }
}

func main() throws {
    var households = 0
    var seedCount = 0
    var configName = "smoke"
    var armFilter: [String]?
    var outDir = "out"
    var dataPath =
        "../../../apps/ios/Resources/data.json"  // repo root, relative to packages/FLTaste/Eval
    var weeksOverride = 0

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        func value(_ name: String) -> String {
            guard !args.isEmpty else {
                fatalError("missing value for \(name)")
            }
            return args.removeFirst()
        }
        switch arg {
        case "--config": configName = value(arg)
        case "--households": households = Int(value(arg)) ?? 0
        case "--seeds": seedCount = Int(value(arg)) ?? 0
        case "--weeks": weeksOverride = Int(value(arg)) ?? 0
        case "--arms": armFilter = value(arg).split(separator: ",").map(String.init)
        case "--out": outDir = value(arg)
        case "--data": dataPath = value(arg)
        default: fatalError("unknown argument: \(arg)")
        }
    }

    var config: CampaignConfig
    switch configName {
    case "smoke": config = .smoke()
    case "full": config = .full()
    case "custom":
        precondition(households > 0 && seedCount > 0, "--config custom needs --households/--seeds")
        config = CampaignConfig(
            householdsPerSeed: households,
            seeds: (0..<seedCount).map { SeedDeriver.child(2026, "campaign-seed", $0) },
            armIDs: armFilter, bootstrapResamples: 10_000, workers: 2,
            weeks: weeksOverride > 0 ? weeksOverride : 13)
    default:
        fatalError("unknown config: \(configName)")
    }
    if households > 0 { config.householdsPerSeed = households }
    if seedCount > 0 {
        config.seeds = (0..<seedCount).map { SeedDeriver.child(2026, "campaign-seed", $0) }
    }
    if weeksOverride > 0 { config.weeks = weeksOverride }
    if let filter = armFilter { config.armIDs = filter }

    let dataURL = URL(fileURLWithPath: dataPath)
    let dataJSON = try String(contentsOf: dataURL, encoding: .utf8)
    let catalog = try CatalogLoader.load(dataJSON: dataJSON)
    let arms = ArmRegistry.all(catalog: catalog).filter { arm in
        config.armIDs.map { $0.contains(arm.id) } ?? true
    }

    let fileManager = FileManager.default
    let checkpointDir = URL(fileURLWithPath: "\(outDir)/checkpoints")
    try fileManager.createDirectory(at: checkpointDir, withIntermediateDirectories: true)

    var roster: [ArmRosterEntry] = []
    for arm in arms {
        roster.append(
            ArmRosterEntry(
                id: arm.id, family: arm.family, rationale: arm.rationale,
                stateless: arm.isStateless))
    }

    let startedAt = ISO8601String(Date())
    var allResults: [ArmSeedResult] = []

    for (armIndex, arm) in arms.enumerated() {
        for seed in config.seeds {
            let checkpoint =
                checkpointDir
                .appendingPathComponent("seed-\(seed)")
                .appendingPathComponent("arm-\(arm.id).json")
            if fileManager.fileExists(atPath: checkpoint.path) {
                let saved = try JSONDecoder().decode(ArmSeedResult.self, from: Data(contentsOf: checkpoint))
                allResults.append(saved)
                print("[resume] \(arm.id) seed \(seed): checkpoint exists, skipping")
                continue
            }

            let armSeed = SeedDeriver.child(seed, "arm-\(arm.id)", armIndex)
            let box = LockedAccumulator()
            let weeks = config.weeks
            let householdsPerSeed = config.householdsPerSeed
            let regimeNames = Regimes.names

            DispatchQueue.concurrentPerform(iterations: householdsPerSeed) { index in
                let (householdConfig, regime) = Regimes.config(
                    seed: seed, householdIndex: index, weeks: weeks)
                let (metrics, resolvedRegime) = Campaign.runHousehold(
                    arm: arm, config: householdConfig, regime: regime, catalog: catalog,
                    householdSeed: householdConfig.seed, armSeed: armSeed)
                precondition(resolvedRegime == regimeNames[index % regimeNames.count])
                box.add(metrics, regime: regime)
            }

            let result = summarize(
                arm: arm.id, family: arm.family, seed: seed,
                households: householdsPerSeed, accumulator: box.value())
            try fileManager.createDirectory(
                at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(result)
            try encoded.write(to: checkpoint)
            allResults.append(result)
            print(
                "[run] \(arm.id) seed \(seed): NDCG \(result.meanNDCG.map { String(format: "%.4f", $0) } ?? "n/a"), violations \(result.restrictionViolations)"
            )
        }
    }

    // Headline statistics.
    var armStats: [ArmStats] = []
    for arm in arms {
        let bySeed = allResults.filter { $0.arm == arm.id }.sorted { $0.seed < $1.seed }
        guard bySeed.count > 1 else { continue }
        let ndcgs = bySeed.compactMap { $0.meanNDCG }
        guard ndcgs.count == bySeed.count else { continue }
        let interval = bootstrap(values: ndcgs, resamples: config.bootstrapResamples, seed: 55)
        let regrets = bySeed.compactMap { $0.meanRegret }
        let regretInterval =
            regrets.count == bySeed.count
            ? bootstrap(values: regrets, resamples: config.bootstrapResamples, seed: 56)
            : nil
        var regimes: [String: Double] = [:]
        for name in Regimes.names {
            let values = bySeed.compactMap { $0.perRegime[name]?.meanNDCG }
            guard !values.isEmpty else { continue }
            regimes[name] = values.reduce(0, +) / Double(values.count)
        }
        armStats.append(
            ArmStats(
                arm: arm.id, family: arm.family, seeds: bySeed.count,
                bootstrapResamples: config.bootstrapResamples,
                meanNDCG: interval.mean, ndcgCI: [interval.low, interval.high],
                meanRegret: regretInterval?.mean,
                regretCI: regretInterval.map { [$0.low, $0.high] },
                meanKendallTau: bySeed.compactMap { $0.meanKendallTau }.mean,
                repeatRate: bySeed.compactMap { $0.repeatRate }.mean,
                meanFairnessGap: bySeed.compactMap { $0.meanFairnessGap }.mean,
                medianRecoveryCooks: bySeed.compactMap { $0.medianRecoveryCooks }.mean,
                restrictionViolations: bySeed.reduce(0) { $0 + $1.restrictionViolations },
                coverageFailures: bySeed.reduce(0) { $0 + $1.coverageFailures },
                perRegimeMeanNDCG: regimes))
    }

    let verdict = gateVerdict(
        results: allResults, engineArm: "engine", ruleArm: "rule-port",
        profileArm: "profile-only", resamples: config.bootstrapResamples)

    // Outputs (sorted keys for stable bytes).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(config).write(to: URL(fileURLWithPath: "\(outDir)/config.json"))
    try encoder.encode(roster).write(to: URL(fileURLWithPath: "\(outDir)/arms.json"))
    try encoder.encode(allResults.sorted { a, b in
        a.seed != b.seed ? a.seed < b.seed : a.arm < b.arm
    })
        .write(to: URL(fileURLWithPath: "\(outDir)/results.json"))
    if let verdict {
        try encoder.encode(verdict).write(to: URL(fileURLWithPath: "\(outDir)/gate.json"))
        print(
            "GATE: \(verdict.activationGateMet ? "MET" : "NOT MET")"
        )
    } else {
        print("GATE: not evaluable (missing arm results)")
    }

    let manifest = RunManifest(
        config: config, arms: roster, startedAt: startedAt,
        hostname: ProcessInfo.processInfo.hostName, swiftVersion: swiftVersionString(),
        corpusPath: dataPath, corpusRecipeCount: catalog.recipes.count,
        note: "suite-B campaign, staged weekly replay, checkpointed per (seed, arm)")
    try encoder.encode(manifest).write(to: URL(fileURLWithPath: "\(outDir)/manifest.json"))
}

func ISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func swiftVersionString() -> String {
    // Fail-soft: the manifest is provenance, not a build requirement.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["swift", "--version"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch {
        return "unknown"
    }
}

// Swift top-level code in an executable target.
try main()
