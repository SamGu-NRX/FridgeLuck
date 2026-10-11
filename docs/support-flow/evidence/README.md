# Evidence and host limits

## What is committed here

- Source-backed contract + tests (`apps/ios/Tools/help-recovery-check`).
- App-side flow (`apps/ios/Feature/Settings/SupportFlow*.swift`) with the
  minimal additive patch to `SettingsHelpView.swift`.
- This evidence note and the journey trace (`../RECOVERY_JOURNEY.md`).

## Native fixture captures - deferred, not faked

The 390x844 and 1440x900 native SwiftUI captures could not be produced in
this environment: the build host is Linux without a Swift/Xcode toolchain,
so no simulator render exists. Per the ground rules, no Playwright/axe or
web-mock render is substituted for a native capture.

To produce the captures on a macOS host:

1. `./scripts/ensure_xcode_project.sh`
2. Run the app on an iPhone simulator (390x844 points) and a 1440x900
   window/host.
3. Navigate: Settings > Help > Fix a problem > expand a topic >
   Diagnostic summary; capture with `xcrun simctl io booted screenshot`.
4. Commit PNGs beside this README with the issue under test named in the
   filename.

Accessibility/contrast results (native, from the same host) should be added
the same way - the flow uses existing `AppTheme` tokens that the app already
ships, but native measurements beat assertions and are deliberately not
claimed here.
