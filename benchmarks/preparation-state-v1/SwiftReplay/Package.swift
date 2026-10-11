// swift-tools-version:5.9
// SwiftReplay: replays preparation-state-v1 probes through the REAL
// production IngredientLexicon source (synced by scripts/sync_production_sources.sh).
// Not runnable on the Linux benchmark sandbox (no Swift toolchain); run on macOS:
//   benchmarks/preparation-state-v1/SwiftReplay/scripts/sync_production_sources.sh
//   swift test --package-path benchmarks/preparation-state-v1/SwiftReplay
//   swift run --package-path benchmarks/preparation-state-v1/SwiftReplay swift-replay < probes.jsonl
import PackageDescription

let package = Package(
    name: "SwiftReplay",
    targets: [
        .target(
            name: "SwiftReplayProduction",
            path: "Sources/SwiftReplayProduction"
        ),
        .executableTarget(
            name: "swift-replay",
            dependencies: ["SwiftReplayProduction"],
            path: "Sources/swift-replay"
        ),
        .testTarget(
            name: "SwiftReplayTests",
            dependencies: ["SwiftReplayProduction"],
            path: "Tests/SwiftReplayTests"
        ),
    ]
)
