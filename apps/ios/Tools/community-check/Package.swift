// swift-tools-version:5.9
// Linux check package for the community-client slice. `refresh.sh` copies the real
// production sources and tests from apps/ios into this package (stripping the app-only
// module imports), pins their SHA-256 hashes in Sources/CommunityCheckKit/HASHES.txt, and
// fails if a copy drifts from the real source. Run: ./refresh.sh && swift test
import PackageDescription

let package = Package(
  name: "community-check",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
  ],
  targets: [
    .target(
      name: "CommunityCheckKit",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/CommunityCheckKit"),
    .testTarget(
      name: "CommunityCheckTests",
      dependencies: ["CommunityCheckKit"],
      path: "Tests/CommunityCheckTests",
      resources: [
        .copy("Fixtures"),
      ]),
  ]
)
