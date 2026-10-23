// swift-tools-version:6.0
import PackageDescription

// Linux-safe evidence package for the substitution harness.
//
// The test target compiles the REAL production sources
// (SubstitutionService.swift and Ingredient.swift) against GRDB on Linux.
// Those sources are not committed here; run Scripts/refresh.sh to copy them
// in from the repository tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/substitution-evidence \
//     -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
//
// A drift test asserts the Real/ copies are byte-identical to the production
// files at run time, so a stale mirror fails loudly instead of passing green.
let package = Package(
  name: "substitution-evidence",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.4.0"..<"4.0.0"),
  ],
  targets: [
    .target(
      name: "SubstitutionEvidence",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Sources/SubstitutionEvidence"
    ),
    .testTarget(
      name: "SubstitutionEvidenceTests",
      dependencies: ["SubstitutionEvidence"],
      path: "Tests/SubstitutionEvidenceTests"
    ),
  ]
)
