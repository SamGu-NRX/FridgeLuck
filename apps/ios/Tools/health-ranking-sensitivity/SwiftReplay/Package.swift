// swift-tools-version:5.9
import PackageDescription

// SwiftReplay: offline replay of FridgeLuck production health scoring.
//  - ProductionReplay: generated vendored production regions (byte-parity claim)
//    + hand-written ReplayEngine (experiment scaffolding, NOT part of the claim).
//  - ExperimentRunner: CLI that runs the perturbation experiment.
//  - ReplayTests: vendored-region parity + bit-exact control parity vs the
//    Python reference fixture.
let package = Package(
  name: "SwiftReplay",
  targets: [
    .target(name: "ProductionReplay"),
    .executableTarget(
      name: "ExperimentRunner",
      dependencies: ["ProductionReplay"]
    ),
    .testTarget(
      name: "ReplayTests",
      dependencies: ["ProductionReplay"],
      path: "Tests/ReplayTests",
      resources: [.copy("fixtures")]
    ),
  ],
  swiftLanguageVersions: [.v5]
)
