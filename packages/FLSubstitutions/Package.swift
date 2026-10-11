// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FLSubstitutions",
    products: [
        .library(name: "FLSubstitutions", targets: ["FLSubstitutions"]),
    ],
    targets: [
        .target(name: "FLSubstitutions"),
        .executableTarget(
            name: "flsub-report",
            dependencies: ["FLSubstitutions"]
        ),
        .testTarget(
            name: "FLSubstitutionsTests",
            dependencies: ["FLSubstitutions"]
        ),
    ]
)
