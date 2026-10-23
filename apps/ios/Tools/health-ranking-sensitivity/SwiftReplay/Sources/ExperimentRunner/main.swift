import Foundation
import ProductionReplay

// Experiment CLI.
//
//   ExperimentRunner --inputs <dir> --outputs <dir>
//
// Reads <dir>/frozen_matrix.json and <dir>/perturbation_bounds.json, runs the
// control arm plus every perturbation arm, and writes raw + aggregate JSON
// into <dir-out>. Deterministic: same inputs, same seed -> same outputs.

func argValue(_ args: [String], _ flag: String) -> String? {
  guard let idx = args.firstIndex(of: flag), args.count > idx + 1 else { return nil }
  return args[idx + 1]
}

do {
  let args = CommandLine.arguments
  guard let inputs = argValue(args, "--inputs"), let outputs = argValue(args, "--outputs") else {
    FileHandle.standardError.write(
      Data("usage: ExperimentRunner --inputs <dir> --outputs <dir>\n".utf8))
    exit(2)
  }

  let matrix: FrozenMatrix = try ReplayEngine.loadJSON(
    FrozenMatrix.self, path: inputs + "/frozen_matrix.json")
  let bounds: BoundsFile = try ReplayEngine.loadJSON(
    BoundsFile.self, path: inputs + "/perturbation_bounds.json")

  print(
    "replaying production scoring at base \(matrix.baseCommit): "
      + "\(matrix.recipes.count) recipes x \(matrix.profiles.count) profiles, "
      + "\(bounds.arms.count) arms, seed \(bounds.drawSeed)")

  let meta = try ReplayEngine.runExperiment(
    matrix: matrix,
    bounds: bounds,
    outputDir: outputs
  )

  let totalDraws = meta.armSummaries.reduce(0) { $0 + $1.draws }
  let rankMoving = meta.armSummaries.reduce(0) { max($0, $1.rankMovingDraws) }
  print(
    "done: \(meta.armSummaries.count) arm-profile summaries, \(totalDraws) draws, "
      + "max rank-moving draws in an arm-profile: \(rankMoving), "
      + "failures recorded: \(meta.failureCount)")
  for s in meta.armSummaries {
    print(
      "  \(s.arm) | \(s.profile): rank-moving draws \(s.rankMovingDraws)/\(s.draws), "
        + "rating flips \(s.ratingFlipsTotal), overlaps \(s.pairwiseOverlappingIntervals)/\(s.pairwiseTotal), "
        + "failures \(s.failures.count), \(s.wallMs) ms")
  }
  exit(0)
} catch {
  FileHandle.standardError.write(Data("EXPERIMENT FAILED: \(error)\n".utf8))
  exit(1)
}
