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

### LeChef tool layer (`backend/gemini-agent/src/lechef/`)

The LeChef assistant runs against a bounded 15-tool runtime: nine proposal
tools (the phone is the authority — explicit approval, or device-auto only for
a timer citing a fresh touch/voice device event) and six honest read tools
(pantry, plan, cook step, food-safety with sourced checks or explicit
unknowns, substitutions with fail-closed allergen rechecks, camera looks that
refuse verdict-shaped text). Wire shapes follow `docs/spec/lechef/contracts/`
with SHA-256 canonical payload hashing, a 300 s proposal TTL, and receipts
that survive kill-and-relaunch (dedupe by proposalID).

```bash
cd backend/gemini-agent
bun run check                              # typecheck
bun test src/__tests__                     # portable tests (incl. contract fixtures)
bun run src/run/lechef-suite.ts            # committed 65-session suite, deterministic report
python3 ../../docs/spec/lechef/contracts/check.py   # schema/fixture contract checker
```

Everything is deterministic and network-free: a `ManualClock`, a fake model,
and a fake phone drive the same runtime the live session will use.
