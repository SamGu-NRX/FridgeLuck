# Periphery in CI: Assessment and Rollout Decision

Date: 2026-03-04

## Decision
- Periphery is meaningful for this repo as an advisory CI signal now.
- Do not make it hard-fail yet.
- Move to strict gating only after baseline/noise triage.

## Why this is meaningful
- The refactor created many moved/split files; dead declarations are more likely.
- Periphery supports:
  - strict mode for fail-on-findings
  - baselines to ratchet down legacy noise
  - index-store scanning for iOS Swift packages
- This makes it suitable for incremental cleanup without blocking delivery immediately.

## Risks to manage
- False positives are common in Swift apps with dynamic usage (SwiftUI previews, Codable mapping, reflection-like paths).
- iOS package indexing requires correct index-store wiring; otherwise scans are noisy or misleading.
- Full strict rollout immediately would create churn and reduce signal.

## Implemented rollout
1. Added `scripts/run_periphery_scan.sh`:
   - builds index store with `xcodebuild`
   - scans with Periphery in app-only scope
   - retains SwiftUI preview + Codable properties
   - writes text + JSON reports to `reports/periphery/`
2. Added `scripts/resolve_ios_sim_destination.sh`:
   - picks an available simulator destination by id for local/CI stability
3. Added GitHub Actions workflow `.github/workflows/ios-ci.yml`:
   - `build-and-test` job (blocking)
   - `dead-code-advisory` job (non-blocking Periphery + artifact upload)
4. Added `scripts/run_ios_tests.sh`:
   - standardizes simulator destination resolution
   - filters one known `.iOSApplication` asset-catalog generator warning line
   - preserves real xcodebuild failures (`set -o pipefail`)

## Graduation criteria to strict mode
- Resolve high-confidence Periphery findings and document intentional keeps.
- Add/commit a baseline file for accepted legacy findings.
- Flip advisory to strict in CI only after consecutive clean scans or a stable baseline.

## Sources
- Periphery README (install, CI usage, strict/baseline flags): https://github.com/peripheryapp/periphery
- Periphery migration docs (v3 CLI updates): https://github.com/peripheryapp/periphery/blob/master/docs/migration_guide.md
- Periphery index-store guidance for platform-specific Swift packages: https://github.com/peripheryapp/periphery/blob/master/docs/indexstores.md
- GitHub Actions workflow syntax (`continue-on-error`): https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
