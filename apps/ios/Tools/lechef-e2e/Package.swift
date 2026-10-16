// swift-tools-version: 5.9
import PackageDescription

// The LeChef end-to-end walk: pinned copies of the real phone sources
// (GeminiLiveSessionClient, LiveProposalCoordinator, CookProposalWire,
// LiveProposalFrames, CookProposalExecutor) plus the walk kitchen and
// driver. ./refresh.sh refreshes the copies and their hashes; ./verify.sh
// checks the pins before building.
let package = Package(
  name: "lechef-e2e",
  dependencies: [
    // Linux has no CryptoKit; the pinned CookProposalWire copy falls back to
    // swift-crypto's Crypto module (same SHA256 API) via the refresh rewrite.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .executableTarget(
      name: "lechef-e2e",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")],
      path: "Sources/lechef-e2e",
      exclude: ["HASHES.txt"]
    )
  ]
)
