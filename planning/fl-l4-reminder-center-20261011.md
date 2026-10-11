# Reminder center (L4) — plan and state model

Task: native reminder workflow on obv/fl-l4-reminder-center from feat/minimal-product-20261007.

## Problem
1. updateRule currently suppresses save errors, so the UI can show "saved" while the database write failed.
2. Permission granted is treated like an alert actually scheduled. Both must be separate explicit states with actual readback.

## Milestones
1. Reminders module: explicit rule-edit / save / schedule / readback states over the existing frozen interfaces (NotificationRuleRepository + public notification interfaces). Tests: failed writes, permission denial, pending requests, concurrent changes; original rules preserved on failure.
2. Reliable edit/enable/disable/time review with explicit retry and actual saved-rule/pending-alert readback. Never derive schedule success from a permission flag or a swallowed refresh exception. Existing coordinator/scheduler behavior reused, no new planning algorithm.
3. Pending-alert view: rule, scheduled time, stock-reference availability, estimated-freshness basis; manage the responsible rule; refresh after foreground/permission/stock changes via existing interfaces; stale callbacks rejected; accessible feedback.
4. Reminder settings entry refactored to the complete flow; stable warm editorial UI; keyboard + VoiceOver paths, large type, ReduceMotion. Native fixture renders (390x844 / 1440x900) + native contrast/accessibility audit evidence; unavailable Apple checks disclosed as unrun.
5. Save -> readback -> refresh -> disable -> relaunch and error-recovery tests against a seeded DB with fake notification center / sync service; hosted native build outcomes committed.

## Frozen (must not modify)
NotificationCoordinator, NotificationScheduler, NotificationRuleRepository, NotificationSyncService, UserNotificationCenterClient, backend planners, shared migrations, SettingsHub/Route/permission clients, held outbound defaults.

## Test safety
Unavailable services are faked and disclosed; no real permissions or paid network in tests; live arms run only with explicit operator scope.
