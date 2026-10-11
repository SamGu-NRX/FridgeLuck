// swift-tools-version: 6.0
import PackageDescription

// Standalone verification package for FridgeLuck's help/recovery contract.
// Pure Foundation, so `swift test --package-path apps/ios/Tools/help-recovery-check`
// runs identically on Linux hosts and macOS.
let package = Package(
  name: "help-recovery-check",
  targets: [
    .target(name: "HelpRecoveryCore", path: "Sources/HelpRecoveryCore"),
    .testTarget(
      name: "HelpRecoveryCoreTests",
      dependencies: ["HelpRecoveryCore"],
      path: "Tests/HelpRecoveryCoreTests"
    ),
  ]
)
