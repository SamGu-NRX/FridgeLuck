// swift-tools-version: 6.0
import PackageDescription

// Part 3 of the FLTaste programme: the suite-B evaluation campaign.
//
// A separate package on purpose, like Part 2's Sim: the parent package
// (../) and the simulator (../Sim) are local path dependencies and are
// never modified here. The executable drives campaigns from the CLI; the
// core library holds arms, the campaign runner, metrics, and statistics so
// tests can exercise everything at smoke scale.
let package = Package(
    name: "FLTasteEval",
    products: [
        .library(name: "FLTasteEvalCore", targets: ["FLTasteEvalCore"]),
        .executable(name: "fltaste-eval", targets: ["FLTasteEval"]),
    ],
    dependencies: [
        .package(path: "../"),
        .package(path: "../Sim"),
    ],
    targets: [
        .target(
            name: "FLTasteEvalCore",
            dependencies: [
                .product(name: "FLTaste", package: "FLTaste"),
                .product(name: "FLTasteSim", package: "Sim"),
            ]
        ),
        .executableTarget(
            name: "FLTasteEval",
            dependencies: [
                "FLTasteEvalCore",
                .product(name: "FLTaste", package: "FLTaste"),
                .product(name: "FLTasteSim", package: "Sim"),
            ]
        ),
        .testTarget(
            name: "EvalTests",
            dependencies: [
                "FLTasteEvalCore",
                .product(name: "FLTaste", package: "FLTaste"),
                .product(name: "FLTasteSim", package: "Sim"),
            ],
            path: "Tests/EvalTests"
        ),
    ]
)
