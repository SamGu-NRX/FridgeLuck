# iOS App

This directory contains the canonical iOS source tree for FridgeLuck.

Structure:

- `App/`: app entrypoints and dependency wiring
- `Feature/`: UI features
- `Platform/`: persistence, services, and platform adapters
- `Domain/`: app models and ports
- `DesignSystem/`: app styling and reusable UI primitives
- `FeatureLogic/`: extracted pure logic used by the app and tests
- `Resources/`: bundled assets and seed data
- `Tests/`: package-level and Xcode-level tests

Notes:

- Open the generated `FridgeLuck.xcodeproj` from the repo root for app development.
- `Package.swift` exists for lightweight package tooling/tests only, not as the app entrypoint.

## Linux logic CI

`.github/workflows/linux-swift.yml` builds and tests the pure-logic subset of this
directory on Linux, in the pinned `swift:6.2.4-noble` container. It runs in addition
to iOS CI (`ios-ci.yml`, `macos-26`), which still builds the full app and runs the
whole suite via `project.yml`/`xcodebuild`. Nothing in the iOS build path changed.

### What is included

`Package.swift` lists sources explicitly, so a file is in the Linux build only if it
is named in the manifest. The included app sources import only `Foundation`, `GRDB`,
`FLFeatureLogic`, and — for logging — `os`; the included test files exercise those
sources (26 test classes, 133 tests, currently green).

### What is excluded, and why

Every file left out is named in the manifest's `exclude` lists (whole directories
where none of the files qualify, individual files where a directory mixes both).
That makes the boundary machine-enforced: a new UI-coupled file cannot enter the
Linux build silently, and SwiftPM's "unhandled files" warning flags any list that
drifts. The exclusion reasons, by category:

- **SwiftUI / UIKit / Vision / HealthKit / UserNotifications / ImageIO / Photos
  imports.** These frameworks do not exist on Linux, and their functionality is not
  shimmed. This covers most of `Feature/`, `DesignSystem/`, `App/`, `Integration/`,
  `Platform/Notifications/`, and several `Capability/` and `Platform/Persistence/`
  services (image storage, meal-log sync, health ingestion, and so on).
- **Combine.** `ObservableObject`/`@Published` are unavailable on Linux
  (`RecommendationEngine` uses them), so the files that use Combine are excluded
  even where the rest of the file is pure logic.
- **URLSession / FoundationNetworking.** Linux moves `URLSession` into
  `FoundationNetworking`; files that perform network I/O (`GeminiCloudAgent`) are
  excluded rather than given a fake networking layer.
- **Cross-file chains.** A file whose only Apple-coupling is a type it *references*
  is excluded if that type lives in an excluded file: `RecommendationEngine` needs
  the `GeminiCloudAgent` type, which needs a type defined in the UIKit-coupled
  `ReverseScanService`. `HelpTutorialReplayRoute` similarly depends on
  `TutorialQuest`, defined in a SwiftUI-importing file.
- **CoreGraphics image types.** Linux Foundation supplies geometry (`CGFloat`,
  `CGRect`, `CGPoint`, `CGSize`) but not `CGImage`. In `ScanContracts.swift` the
  import and the `ScanInput` struct (the only CGImage carrier, used solely by the
  iOS camera pipeline) are wrapped in `#if canImport(CoreGraphics)`; the Apple-side
  preprocessor result is byte-identical to before.
- **`@MainActor` test classes.** `AppPermissionCenterTests` is annotated
  `@MainActor`. The Linux `corelibs-xctest` runner crashes while building the test
  list (it cannot force-cast `@MainActor` test-method types), so the file is
  excluded — excluding it was required for *any* Linux test to run.
- **UI-coupled test files.** Tests whose subjects import the frameworks above
  (spotlight/settings/kitchen/notification flows, recipe chips, capture lifecycle,
  and so on) stay with the iOS job.

### Linux-only additions

Two additive, Linux-only mechanisms exist. Neither changes any Apple-platform
behavior:

- `LinuxSupport/os/` — a logging-only shim module named `os` so files that log
  through `os.Logger` compile. It implements logging exclusively; it never stands
  in for functional Apple-framework APIs, and it is wired into the target on Linux
  only (`#if os(Linux)` in the manifest).
- `LinuxSupport/AppLogic/LinuxCompatibility.swift` — Foundation-level constants
  whose definition of record lives in an excluded Apple-coupled file. Currently one
  entry: `Notification.Name.inventoryDidChange`, mirrored from
  `NotificationCoordinator.swift` (UIKit-importing). The value must match the iOS
  definition; the file cross-references the definition of record and must be
  updated in the same commit if it changes. `NotificationCenter` itself is
  Foundation and works on Linux; nothing functional is shimmed.

### Verifying the gate

- `swift build` and `swift test` in `apps/ios` on any Linux machine with a Swift
  6.2.x toolchain (the CI container is pinned to 6.2.4).
- The gate catches logic breakage: with a deliberately inverted toggle in
  `CookingGuideStateTransitions`, the Linux run fails (`testToggleIngredientRemovesExistingIngredient`)
  and passes again once the change is reverted.

