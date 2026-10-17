# Privacy manifest evidence — FridgeLuck (`PrivacyInfo.xcprivacy`)

Audited revision: `8c9c88fed3007b8ce0f81f8b5684461f5ff698bc` (`origin/feat/minimal-product-20261007`).
Cross-checked against PR #20's data-flow memo (`docs/privacy-data-flow.md`, branch `docs/data-flow-audit`), which was read without modification.

## Method

1. Source inventories at the audited revision: grep/sed sweeps over `apps/ios/` for every required-reason API surface (UserDefaults, file metadata, boot time, disk space, keyboards) and every outbound-data surface (URLSession, URLSessionWebSocketTask, HKHealthStore, AVAudioEngine, Vision, Firebase/Sentry/analytics imports, App Groups, Keychain, pasteboard, StoreKit, web views, location, ATT).
2. Cross-check against PR #20's memo, which reached the same six-flow map from a backend-inclusive audit.
3. Apple declarations verified against primary documentation retrieved 2026-10-09 (doc JSON behind developer.apple.com, not summaries):
   - `NSPrivacyAccessedAPIType` key page (reason tables for all five categories).
   - `NSPrivacyCollectedDataType` key page (enum values and definitions).
4. Packaging path verified in `project.yml` and XcodeGen's file-type source; final proof is the hosted CI test (below).

## Required-reason API declarations

| API use (source, revision) | Category | Reason | Why the reason fits |
|---|---|---|---|
| `BundledDataLoaderUSDACatalog.swift:127-131` reads `fileSizeKey` + `contentModificationDateKey` of `usda_ingredient_catalog.sqlite` (bundle resource, `Bundle.main.url` at `:8`); marker stored locally in `usda_catalog_state` (`:135-143`) | `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Apple: "access the timestamps, size, or other metadata of files inside the app container…" — the file is inside the app bundle; both size and timestamp read; derived marker stays on-device |
| All UserDefaults usage is `UserDefaults.standard` with app-only keys: `ContentView.swift:158`, `:879`; `AppPreferencesStore.swift:60-90` (`appPref_*`); `FirstRunExperienceStore.swift:10-31` (`firstRun*`); `LearningService.swift:15-22` (`learning_*`); `DemoModeView.swift:28`; `HomeDashboardView.swift:23-35`; `IngredientReviewView.swift:97-98`; `RecipePreviewDrawer.swift:24`; `SettingsHelpView.swift:6`; `NotificationSyncService.swift:26`, `:118-126` (`notificationSync_installationId`); launch reset `MyApp.swift:89-99` | `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Apple: "access user defaults to read and write information that is only accessible to the app itself" — no App Groups (none declared in `project.yml`), no MDM keys, custom suites appear only in test setup (`Tests/SettingsFlowTests.swift:63-66`) |

Deliberately absent categories (zero grep hits at the audited revision): `SystemBootTime` (`systemUptime`, `mach_absolute_time`, `KERN_BOOTTIME`), `DiskSpace` (`volume*`, `systemFreeSize`, `statfs`), `ActiveKeyboards` (`activeInputModes`).

## Collected data declarations

All entries: `tracking=false` (no ads SDKs, no data brokers, no cross-app or cross-site linkage anywhere in the binary), purpose `AppFunctionality`. All entries `linked=true` — conservative posture, justification below the table.

| Flow | Data | Declaration | Sources |
|---|---|---|---|
| Notification plan | Persistent per-install UUID (`notificationSync_installationId`, created once and persisted) | `DeviceID` (install-scoped; no accounts exist per PR #20) | `NotificationSyncService.swift:26`, `:60`, `:118-126`; `project.yml:116` |
| Notification plan | Timezone + locale identifiers, sent with the UUID above | `OtherDataTypes` | `NotificationSyncService.swift:61-62` |
| Notification plan | Inventory snapshot: ingredient names, grams, expiry, confidence — sent with the UUID above | `OtherUserContent` | `NotificationSyncService.swift:73-82` |
| Recipe generation | Ingredient names, dietary restrictions, scan confidence, fridge photo (JPEG 0.72, base64) | `OtherUserContent` + `Health` + `PhotosorVideos` | `GeminiCloudAgent.swift:369`, `:372-375`; `RecipeResultsView.swift:158` |
| Direct Gemini fallback | Same payload to `generativelanguage.googleapis.com` (only when `GEMINI_API_KEY` is set) | same types | `GeminiCloudAgent.swift:282`, `:286`, `:291-296`, `:303` |
| Reverse scan | Photo JPEG 0.72, detection labels, candidate titles | `PhotosorVideos` + `OtherUserContent` | `ReverseScanService.swift:136-141`; `GeminiCloudAgent.swift:404`, `:426` |
| Live assistant (WSS) | Recipe title/instructions/ingredients/quantities, user text, camera frames (JPEG 0.55, ≤1 fps), microphone PCM16 while listening | `OtherUserContent` + `PhotosorVideos` + `AudioData` | `GeminiLiveSessionClient.swift:26-39`, `:60-90`, `:119-126`, `:140-146`; `LiveAssistantViewModel.swift:206`; `LiveAssistantCaptureCoordinator.swift:39-53`, `:118-126` |

**Health** covers only the dietary/allergen restrictions the user enters into the local `health_profile` table (`Migrations.swift:63`) that travel inside recipe payloads (`GeminiCloudAgent.swift:84`, `:373`). HealthKit reads/writes (`AppleHealthService.swift:36-43`, `:150-235`) never leave the device and are **not** declared.

**Linked=true justification (conservative):** the notification-plan request demonstrates persistent identifier association by design (a stable per-install UUID travels with timezone, locale, and inventory content); the backend additionally stores `latestCameraFrame` and `lastUserMessage` keyed by session UUID (PR #20 memo §3); all flows share one operator backend. Provider/infra logging behavior is unknown (see open questions), so every transmitted type is declared linked rather than guessing linkage away.

## Deliberately NOT declared (local-only)

| Surface | Evidence (revision) |
|---|---|
| HealthKit read/write (nutrition totals, meal logging) | `AppleHealthService.swift` — `HKHealthStore` only, no network calls in file |
| Meal photos on disk | `ImageStorageService.swift:7-24` (Application Support/MealPhotos), never transmitted |
| SQLite database | `AppDatabase.swift:66` (Application Support/fridgeluck.db) |
| Scan diagnostics | `ScanRunStore.swift:127-139` (local JSON snapshots) |
| Vision on-device inference | PR #20 memo §4; no CoreML/MLModel network surface |
| All UserDefaults values except the transmitted installation ID | table above |

Negative sweep at the audited revision: no `advertisingIdentifier`/AdSupport/AppTrackingTransparency, no Firebase/Sentry/analytics SDKs, no App Group identifiers, no SecItem/Keychain use, no WKWebView/SFSafariView, no UIPasteboard, no CoreLocation, no BGTaskScheduler, no SFSpeechRecognizer (transcription happens server-side), no StoreKit, no `systemUptime`/disk-space APIs. `project.yml:106` declares a Sign in with Apple entitlement with no corresponding code — flagged, untouched.

## Packaging evidence chain

1. `project.yml:70` includes `apps/ios/Resources` in the app target's sources; the tests target's sources are `apps/ios/Tests` only (`project.yml:41-43`), hosted by the app (`TEST_HOST`, `project.yml:56`).
2. XcodeGen's `defaultFileTypes` (`Sources/ProjectSpec/FileType.swift`, read 2026-10-09) has no `.xcprivacy` entry; unknown extensions default to the resources phase — the same class as the already-bundled `.json`/`.sqlite`/`.png` resources in this directory (e.g. `usda_ingredient_catalog.sqlite` loads from `Bundle.main` at `BundledDataLoaderUSDACatalog.swift:8`).
3. iOS CI (`.github/workflows/ios-ci.yml`: `pull_request`, `macos-26`, `ensure_xcode_project.sh` runs `xcodegen generate`, then `run_ios_tests.sh` runs hosted `xcodebuild test`) executes `PrivacyManifestTests` inside `FridgeLuck.app` on this PR — the `testPrivacyManifestIsBundledInHostedApp` pass/fail on the CI run for this PR is the packaging proof.

## Verification commands (run 2026-10-09)

- `python3 scripts/validate_privacy_manifest.py --manifest apps/ios/Resources/PrivacyInfo.xcprivacy --expect-app` → PASS
- `python3 scripts/validate_privacy_manifest.py --self-test` → PASS (1 valid fixture accepted, 9 negative mutations rejected)
- Hosted Swift tests (`PrivacyManifestTests`, 12 cases: 2 positive + 10 mutations) → verified by iOS CI on this PR

## Open questions / assumptions

1. **`linked=true` posture** — conservative; reverse for flows #1-#4 only if the operator removes identifier association server-side (the persistent UUID, session-UUID-keyed store, or infra logging).
2. **`Health` classification** covers transmitted dietary/allergen restrictions only; alternative reading is `OtherUserContent` (preferences, not medical data). HealthKit data is never transmitted either way.
3. **`DeviceID` vs `UserID`** for the install UUID: no accounts exist (PR #20), so install-scoped `DeviceID` was chosen.
4. **Default-on notification sync** (flow #5) is the only egress without a per-use user action; consent/UX posture is PR #20's open backend-default decision.
5. **Provider retention unknowns** — Cloud Run/Gemini logging and the deployed session store (PR #20 §3/§5) are not addressed here.
6. **Sign in with Apple entitlement** with no auth code — entitlement/utility question, out of scope.
