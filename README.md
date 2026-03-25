# FridgeLuck

WIP setup notes for local development.

## iOS project setup

This repo uses XcodeGen. The source of truth for the Xcode project is `project.yml`.
Use the generated Xcode project for all app deployment and device testing.
Do not open `apps/ios/Package.swift` in Xcode for app runs; Xcode 26 may treat it as a Swift Playground-style project, which limits capabilities like HealthKit.

Generated files are intentionally ignored and should not be committed:

- `FridgeLuck.xcodeproj/`
- `Xcode/FridgeLuck-Info.plist`
- `Xcode/FridgeLuck.entitlements`

Regenerate the project locally with:

```bash
xcodegen generate
```

That will recreate the Xcode project from `project.yml` for local use.

Or use the helper script:

```bash
./scripts/open_ios_project.sh
```

### Repo layout

- `apps/ios/`: canonical iOS source tree (`App`, `Feature`, `Platform`, `Domain`, `DesignSystem`, `Resources`, `Tests`)
- `backend/`: TypeScript / backend services
- `scripts/`: cross-repo automation and data pipelines
- `FridgeLuck.xcodeproj/`: generated local artifact, not a source-of-truth folder

### Canonical workflow

1. Generate and open `FridgeLuck.xcodeproj`.
2. Select the `FridgeLuck` app target.
3. Run on simulator or device from that target only.

### HealthKit

HealthKit capability configuration lives in `project.yml`.
If Apple Health shows as unavailable on device, confirm the signed app actually contains the entitlement:

```bash
./scripts/verify_healthkit_entitlement.sh
```

If the script reports that `com.apple.developer.healthkit` is missing, the app was signed without HealthKit capability for that device build. Under a Personal Team, the app should degrade cleanly to Apple Health being unavailable instead of failing at runtime.

If a device build fails earlier with a provisioning-profile error saying `HealthKit` or `Sign in with Apple` is not included, the selected team/profile cannot sign those capabilities for this app. In that case, switch to a team/profile that supports those capabilities before expecting Apple Health to be connectable on device.
