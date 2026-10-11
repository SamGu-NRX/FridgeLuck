# Support flow recovery journey (fixture-based trace)

Scope: the fake-state recovery journey defined by the canonical contract in
`apps/ios/Tools/help-recovery-check` (HelpRecoveryCore) and its app mirror in
`apps/ios/Feature/Settings/SupportFlowContent.swift`.

## Contract verification status

- `swift test --package-path apps/ios/Tools/help-recovery-check`: **not run in
  this sandbox** (Linux host without a Swift toolchain). The package is pure
  Foundation and targets `swift-tools 6.0`; the 12 deterministic tests pin:
  exact plans for all 8 issues, unwired-host filtering, no-reset invariant,
  real-destination invariant, export allowlist, sentinels, and cancellation.
- The PR's iOS CI (macos-26, Xcode 26.6) builds and tests the app target on
  every `pull_request` run - that is the first executed check for the
  app-side files. Adding the Tools package to a CI job is a workflow edit,
  which is excluded by rule, so it is recorded as a follow-up instead.

## Journey (deterministic fixtures)

Each row is the contract's `SupportRecoveryMapping.plan(for:wiring:)` output
with a fully wired host, as asserted by `SupportRecoveryTests`.

| Stuck state | Ordered recovery actions | Never happens |
| --- | --- | --- |
| cameraAccessDenied | openPermissionSettings, retryScan | profile/history reset; tour forced |
| photoLibraryAccessDenied | openPermissionSettings, chooseDifferentInput | history reset |
| partialScan | retryScan, manualEntry | diagnostics discarded; tour forced |
| emptyRecognition | retryScan, manualEntry | "bad content" claim; tour forced |
| cloudUnavailable | retryCloudRequest, manualEntry | local flow blocked on cloud |
| localSaveFailed | retryLocalSave, openDiagnosticsPreview | partial history write |
| healthAuthorizationIncomplete | openPermissionSettings | silent data writes |
| notificationAuthorizationIncomplete | openPermissionSettings | rules deleted |

Unwired host: actions with `requiresHostWiring` are filtered out, not shown
disabled - a control is never enabled when its destination is a stub.

## Navigation

- Entry: Settings > Help > "Fix a problem" (sheet; settings routing files
  untouched).
- Settings actions open `UIApplication.openSettingsURLString` via
  `@Environment(\.openURL)` and return by the system back path.
- Replay actions dismiss the sheet and invoke the pre-existing
  `onReplayQuest` / `onReplayOnboarding` callbacks unchanged.
- Diagnostics preview is an in-sheet push with an explicit Cancel that
  discards; sharing goes through the user's own share sheet.

## Package / hosted checks

- Tools package: covered by `swift test` above (unrun locally, fixtures
  deterministic; CI runs the app suite).
- Hosted-app checks: not applicable - this flow ships inside the iOS app and
  the Tools package; no web asset is produced.
