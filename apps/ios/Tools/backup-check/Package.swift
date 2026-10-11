// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for the local backup archive and staged restore.
//
// The test target compiles the REAL production persistence sources
// (apps/ios/Platform/Persistence) against GRDB on Linux. Those sources are
// not committed here; run Scripts/refresh.sh to copy them in from the
// repository tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/backup-check \
//     -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
let package = Package(
  name: "backup-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.4.0"..<"4.0.0"),
  ],
  targets: [
    .target(
      name: "BackupCheck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Sources/BackupCheck"
    ),
    .testTarget(
      name: "BackupCheckTests",
      dependencies: ["BackupCheck"],
      path: "Tests/BackupCheckTests"
    ),
  ]
)
