# FridgeLuck

WIP setup notes for local development.

## iOS project setup

This repo uses XcodeGen. The source of truth for the Xcode project is `project.yml`.

Generated files are intentionally ignored and should not be committed:

- `FridgeLuck.xcodeproj/`
- `Xcode/FridgeLuck-Info.plist`
- `Xcode/FridgeLuck.entitlements`

Regenerate the project locally with:

```bash
xcodegen generate
```

That will recreate the Xcode project from `project.yml` for local use.
