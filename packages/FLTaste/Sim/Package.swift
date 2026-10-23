// swift-tools-version: 6.0
import PackageDescription

// Part 2 of the FLTaste programme: the household simulator.
//
// A separate package on purpose: Part 1 owns packages/FLTaste/Package.swift,
// and the simulator must not touch it. The parent package is a local path
// dependency, so the contract smoke test runs against the real TasteEngine.
let package = Package(
    name: "FLTasteSim",
    products: [
        .library(name: "FLTasteSim", targets: ["FLTasteSim"])
    ],
    dependencies: [
        .package(path: "../")
    ],
    targets: [
        .target(
            name: "FLTasteSim",
            dependencies: ["FLTaste"]
        ),
        .testTarget(
            name: "SimTests",
            dependencies: ["FLTasteSim", "FLTaste"]
        )
    ]
)
