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
