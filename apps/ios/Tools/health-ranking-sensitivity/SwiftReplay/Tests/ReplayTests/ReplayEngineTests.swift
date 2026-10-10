import XCTest
@testable import ProductionReplay

// Engine-logic tests: perturbation correctness properties that the parity
// tests do not cover (zeros are real measurements, bounded draws, determinism,
// sort stability). All use the committed frozen matrix + bounds.

final class ReplayEngineTests: XCTestCase {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/ReplayTests
  static let sensRoot = root
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // SwiftReplay
    .deletingLastPathComponent()  // health-ranking-sensitivity

  static func load(name: String) -> Data {
    let url = sensRoot.appendingPathComponent(name)
    return try! Data(contentsOf: url)
  }

  static func makeFixture() -> (FrozenMatrix, BoundsFile) {
    let matrix = try! JSONDecoder().decode(
      FrozenMatrix.self, from: load(name: "inputs/frozen_matrix.json"))
    let bounds = try! JSONDecoder().decode(
      BoundsFile.self, from: load(name: "inputs/perturbation_bounds.json"))
    return (matrix, bounds)
  }

  func testExactZerosSurvivePerturbation() throws {
    let (matrix, bounds) = Self.makeFixture()
    let arm = ResolvedArm(
      spec: ArmSpec(id: "t", description: "", nutrientBoundsRef: "stress.nutrients_pct",
                    portionScaleRef: "stress.portion_scale_pct", draws: 1, stress: true),
      nutrients: bounds.stress.nutrientsPct,
      portionPct: bounds.stress.portionScalePct)
    // Find any recipe with a zero macro field (matrix guarantees them).
    let zero = matrix.recipes.first { r in
      let m = r.macrosPerServing
      return m.fiberG == 0 || m.sugarG == 0 || m.sodiumMg == 0
    }
    let row = try XCTUnwrap(zero, "frozen matrix must contain zero-macro recipes")
    for draw in 0..<50 {
      let p = perturbed(
        row.macrosPerServing, arm: arm,
        seedMaterial: "t|P1|\(draw)|0", drawSeed: bounds.drawSeed)
      if row.macrosPerServing.fiberG == 0 { XCTAssertEqual(p.fiberG, 0, "draw \(draw)") }
      if row.macrosPerServing.sugarG == 0 { XCTAssertEqual(p.sugarG, 0, "draw \(draw)") }
      if row.macrosPerServing.sodiumMg == 0 { XCTAssertEqual(p.sodiumMg, 0, "draw \(draw)") }
    }
  }

  func testPerturbedValuesStayInsideCommittedBounds() throws {
    let (matrix, bounds) = Self.makeFixture()
    let arms = try resolveArms(bounds).filter { $0.nutrients != nil || $0.portionPct != nil }
    for arm in arms {
      let nutrientMax = arm.nutrients.map {
        max($0.calories, $0.protein, $0.carbs, $0.fat, $0.fiber, $0.sugar, $0.sodium)
      }
      // Joint arms compound: (1+n)(1+p)-1, not max(n, p).
      let limit: Double
      switch (nutrientMax, arm.portionPct) {
      case let (n?, p?):
        limit = (1.0 + n / 100.0) * (1.0 + p / 100.0) - 1.0 + 1e-9
      case let (n?, nil):
        limit = n / 100.0 + 1e-9
      case let (nil, p?):
        limit = p / 100.0 + 1e-9
      default:
        continue
      }
      for draw in 0..<40 {
        for (idx, r) in matrix.recipes.enumerated() {
          let base = r.macrosPerServing
          let p = perturbed(
            base, arm: arm, seedMaterial: "t|P1|\(draw)|\(idx)", drawSeed: bounds.drawSeed)
          for (name, b, v) in [
            ("calories", base.calories, p.calories), ("protein", base.proteinG, p.proteinG),
            ("carbs", base.carbsG, p.carbsG), ("fat", base.fatG, p.fatG),
            ("fiber", base.fiberG, p.fiberG), ("sugar", base.sugarG, p.sugarG),
            ("sodium", base.sodiumMg, p.sodiumMg),
          ] {
            if b != 0 {
              let deviation = abs(v / b - 1.0)
              XCTAssertLessThanOrEqual(
                deviation, limit,
                "\(arm.spec.id) draw \(draw) \(name): \(deviation) > \(limit)")
            } else {
              XCTAssertEqual(v, 0, "\(arm.spec.id) draw \(draw) \(name): zero not preserved")
            }
          }
        }
      }
    }
  }

  func testExperimentIsDeterministicAcrossRuns() throws {
    let (matrix, bounds) = Self.makeFixture()
    let a = try ReplayEngine.runExperiment(
      matrix: matrix, bounds: bounds, outputDir: NSTemporaryDirectory() + "/replay-a",
      rawSampleDraws: 3)
    let b = try ReplayEngine.runExperiment(
      matrix: matrix, bounds: bounds, outputDir: NSTemporaryDirectory() + "/replay-b",
      rawSampleDraws: 3)
    // wallMs is timing metadata, not a measurement: strip it before comparing.
    var a2 = a
    var b2 = b
    a2.armSummaries = a.armSummaries.map { s in
      var s = s
      s.wallMs = 0
      return s
    }
    b2.armSummaries = b.armSummaries.map { s in
      var s = s
      s.wallMs = 0
      return s
    }
    // Canonical encoding: sorted keys so dictionary order (per-process
    // random in Swift) cannot leak into the comparison.
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let ea = try enc.encode(a2)
    let eb = try enc.encode(b2)
    XCTAssertEqual(ea, eb, "same seed and inputs must reproduce identical run metadata")
  }

  func testControlRecordsAreStableAcrossCalls() throws {
    let (matrix, _) = Self.makeFixture()
    let a = ReplayEngine.controlRecords(matrix: matrix, profile: matrix.profiles[0])
    let b = ReplayEngine.controlRecords(matrix: matrix, profile: matrix.profiles[0])
    XCTAssertEqual(a, b, "control arm must be exactly reproducible")
    XCTAssertEqual(a.count, matrix.recipes.count)
  }

  func testUntiedRecipesKeepTheirOrder() throws {
    // Two recipes far apart in score: higher score must always rank first.
    let (matrix, _) = Self.makeFixture()
    let records = ReplayEngine.controlRecords(matrix: matrix, profile: matrix.profiles[0])
    for i in 0..<(records.count - 1) {
      XCTAssertGreaterThanOrEqual(
        records[i].rankingScore, records[i + 1].rankingScore,
        "rank order must be non-increasing in ranking score")
    }
  }
}
