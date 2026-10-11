// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LabelNumbersReplay",
    targets: [
        .target(name: "LabelNumbersReplay"),
        .executableTarget(
            name: "label-numbers-replay",
            dependencies: ["LabelNumbersReplay"]
        ),
        .testTarget(
            name: "LabelNumbersReplayTests",
            dependencies: ["LabelNumbersReplay"]
        ),
    ]
)
