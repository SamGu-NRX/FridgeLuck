// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FLTaste",
    products: [
        .library(name: "FLTaste", targets: ["FLTaste"])
    ],
    targets: [
        .target(
            name: "FLTaste"
        ),
        .testTarget(
            name: "FLTasteTests",
            dependencies: ["FLTaste"],
            resources: [.copy("Fixtures")]
        )
    ]
)
