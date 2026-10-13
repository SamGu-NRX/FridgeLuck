#!/usr/bin/env python3
"""Verify every file:line reference cited in docs/privacy-data-flow.md.

Each ref is a (path, line, expected-substring) triple. Main-branch refs are
checked against the working tree (run from `main`); PR-head refs are checked
against `git show <sha>:<path>`. Exits non-zero on any mismatch.

Usage: python3 docs/check_refs.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

MAIN_SHA = "1151588d6bc6f5dcc3e848b6115813ff36ffbf0d"

PR_13 = "3e6d321f1a405be4b96aab37dd69aa7ac3df5491"
PR_5 = "30f341847cec43b2788301ee07ee1e6a8cddb568"
PR_4 = "8c9c88fed3007b8ce0f81f8b5684461f5ff698bc"

# (path, line, expected substring). Paths are repo-relative.
MAIN_REFS: list[tuple[str, int, str]] = [
    # project config: backend URL default
    ("project.yml", 79, "GEMINI_BACKEND_BASE_URL"),
    ("project.yml", 116, "https://fridgeluck-gemini-agent"),
    # flow #1: recipe generation via backend
    ("apps/ios/Feature/Results/RecipeResultsView.swift", 143, "generateAIRecipe"),
    ("apps/ios/Capability/Core/Services/RecommendationEngine.swift", 171, "Routing recipe generation to cloud"),
    ("apps/ios/Capability/Core/Services/RecommendationEngine.swift", 173, "geminiCloudAgent.generateRecipe"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 22, "GEMINI_BACKEND_BASE_URL"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 27, "GEMINI_BACKEND_BASE_URL"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 82, "func generateRecipe"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 124, "ingredientNames"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 126, "dietaryRestrictions"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 144, "scan_confidence_score"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 361, "generateRecipeViaBackend"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 372, "ingredientNames"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 375, "photoBase64JPEG"),
    ("backend/gemini-agent/src/server.ts", 41, "/v1/recipes/generate"),
    ("backend/gemini-agent/src/server.ts", 54, "generateRecipe(ai, config, payload)"),
    ("backend/gemini-agent/src/services/recipeService.ts", 13, "image/jpeg"),
    ("backend/gemini-agent/src/services/recipeService.ts", 50, "generateContent"),
    # flow #2: direct Gemini fallback
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 23, "GEMINI_API_KEY"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 30, "GEMINI_API_KEY"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 73, "not configured"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 77, "isConfigured"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 286, "generativelanguage.googleapis.com"),
    # flow #3: reverse-scan re-ranking
    ("apps/ios/Capability/Core/Services/ReverseScanService.swift", 136, "preferLocal"),
    ("apps/ios/Capability/Core/Services/ReverseScanService.swift", 137, "if !preferLocal"),
    ("apps/ios/Capability/Core/Services/ReverseScanService.swift", 140, "compressionQuality: 0.72"),
    ("apps/ios/Capability/Core/Services/ReverseScanService.swift", 141, "rankReverseScanCandidates"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 177, "func rankReverseScanCandidates"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 426, "photoBase64JPEG"),
    ("apps/ios/Capability/Core/Intelligence/GeminiCloudAgent.swift", 570, "let ingredientNames"),
    ("backend/gemini-agent/src/server.ts", 63, "/v1/reverse-scan/rank"),
    # flow #4: live assistant
    ("apps/ios/App/ContentView.swift", 743, "presentLiveAssistant"),
    ("apps/ios/App/ContentView.swift", 757, "liveAssistantRoute = LiveAssistantRoute("),
    ("apps/ios/Feature/Assistant/LiveAssistantModels.swift", 18, "struct LiveAssistantRecipeContext"),
    ("apps/ios/Support/AdditionalInfo.plist", 7, "NSCameraUsageDescription"),
    ("apps/ios/Support/AdditionalInfo.plist", 16, "NSMicrophoneUsageDescription"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 38, "/v1/live"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 103, "session_context"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 116, "client_content"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 119, "func sendImageFrame"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 125, '"data"'),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 142, "realtime_input"),
    ("apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift", 145, "audio/pcm"),
    ("apps/ios/Feature/Assistant/LiveAssistantCaptureCoordinator.swift", 119, "1.0"),
    ("apps/ios/Feature/Assistant/LiveAssistantCaptureCoordinator.swift", 125, "compressionQuality: 0.55"),
    ("apps/ios/Feature/Assistant/LiveAssistantViewModel.swift", 26, "isListening"),
    ("apps/ios/Feature/Assistant/LiveAssistantViewModel.swift", 241, "isListening"),
    ("backend/gemini-agent/src/server.ts", 159, "upgrade"),
    # flow #5: notification sync
    ("apps/ios/Platform/Notifications/NotificationCoordinator.swift", 46, "handleAppDidBecomeActive"),
    ("apps/ios/Platform/Notifications/NotificationCoordinator.swift", 79, "rule.enabled"),
    ("apps/ios/Platform/Notifications/NotificationCoordinator.swift", 96, "makeLocalFallbackOpportunities"),
    ("apps/ios/Platform/Notifications/NotificationCoordinator.swift", 103, "rule.enabled"),
    ("apps/ios/Domain/Models/NotificationModels.swift", 12, "useSoonAlerts"),
    ("apps/ios/Domain/Models/NotificationModels.swift", 50, "defaultEnabled"),
    ("apps/ios/Platform/Persistence/Repository/NotificationRuleRepository.swift", 109, "seedDefaultsIfNeeded"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 26, "installationId"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 61, "timezone"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 62, "locale"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 73, "inventorySnapshot"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 84, "v1/notifications/plan"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 118, "installationId"),
    ("apps/ios/Platform/Notifications/NotificationSyncService.swift", 124, "installationId"),
    ("backend/gemini-agent/src/server.ts", 122, "/v1/notifications/plan"),
    # flow #6: Apple Health
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 36, "quantityIdentifiers"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 43, "dietarySodium"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 155, "makeFoodCorrelation"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 159, "healthStore.save"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 293, "let fields"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 320, "correlationMetadata"),
    ("apps/ios/Platform/Persistence/Services/AppleHealthService.swift", 322, "HKMetadataKeyFoodType"),
    ("apps/ios/Platform/Persistence/Services/MealLogSyncCoordinator.swift", 19, "func syncLoggedMeal"),
    ("apps/ios/Platform/Persistence/Services/MealLogService.swift", 43, "imageStorageService.save"),
    ("apps/ios/Support/AdditionalInfo.plist", 18, "NSHealthShareUsageDescription"),
    ("apps/ios/Support/AdditionalInfo.plist", 20, "NSHealthUpdateUsageDescription"),
    # backend retention & logging
    ("backend/gemini-agent/src/config.ts", 3, "SessionStoreMode"),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 45, "confirmedIngredients"),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 101, "const mode ="),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 108, 'mode === "firestore"'),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 154, "latestCameraFrame"),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 165, "latestConfidence"),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 175, "mutationAudit"),
    ("backend/gemini-agent/src/session/liveSessionStore.ts", 189, "lastUserMessage"),
    ("backend/gemini-agent/src/agent/toolRegistry.ts", 48, "assess_live_scene"),
    ("backend/gemini-agent/src/agent/toolRegistry.ts", 79, "ground_food_safety"),
    ("backend/gemini-agent/src/agent/toolRegistry.ts", 96, "mutate_inventory"),
    ("backend/gemini-agent/src/observability/tracing.ts", 12, "console.log(formatTrace(trace))"),
    ("backend/gemini-agent/src/observability/tracing.ts", 20, "console.log("),
    ("backend/gemini-agent/src/observability/tracing.ts", 52, "sessionId"),
    ("backend/gemini-agent/src/api/webhooks.ts", 56, "cloud_task_received"),
    ("backend/gemini-agent/src/inventory/inventoryLedger.ts", 13, "class InventoryLedger"),
    ("backend/gemini-agent/src/inventory/inventoryLedger.ts", 14, "new Map"),
    ("backend/gemini-agent/src/server.ts", 145, "createWebhookRouter"),
    # local-only storage
    ("apps/ios/Platform/Persistence/Database/AppDatabase.swift", 66, "fridgeluck.sqlite"),
    ("apps/ios/Platform/Persistence/Database/Migrations.swift", 206, "image_path"),
    ("apps/ios/Platform/Persistence/Database/Migrations.swift", 449, "notification_rules"),
    ("apps/ios/Platform/Persistence/Services/ImageStorageService.swift", 7, "MealPhotos"),
    ("apps/ios/Platform/Persistence/Services/ImageStorageService.swift", 8, "0.82"),
    ("apps/ios/Platform/Persistence/Services/ImageStorageService.swift", 13, "func save"),
    ("apps/ios/Platform/Persistence/Services/ImageStorageService.swift", 19, "maxDimension: 1200"),
    ("apps/ios/Platform/Persistence/Services/ImageStorageService.swift", 41, "func delete(relativePath"),
    ("apps/ios/Capability/Core/Services/ScanRunStore.swift", 52, "maxRecords"),
    ("apps/ios/Capability/Core/Services/ScanRunStore.swift", 131, "scan_run_records.json"),
    ("apps/ios/Capability/Core/Recognition/VisionService.swift", 10, "VNRecognizeTextRequest"),
    ("apps/ios/Capability/Core/Recognition/VisionService.swift", 369, "VNClassifyImageRequest"),
    ("apps/ios/Platform/Persistence/Services/PersonalizationService.swift", 65, "imagePath"),
    ("apps/ios/Platform/Persistence/Services/PersonalizationService.swift", 73, "imagePath: imagePath"),
    # user controls & reset
    ("apps/ios/Feature/Settings/SettingsDataAndPrivacyView.swift", 11, "FLSettingsFootnote("),
    ("apps/ios/Feature/Settings/SettingsDataAndPrivacyView.swift", 16, "Open iOS Settings"),
    ("apps/ios/Feature/Settings/SettingsDataAndPrivacyView.swift", 22, "FLSettingsDestructiveGroup("),
    ("apps/ios/App/ContentView.swift", 843, "func performFullReset"),
    ("apps/ios/Platform/Persistence/Repository/UserDataRepository.swift", 158, "func resetAllUserData"),
    ("apps/ios/Platform/Persistence/Repository/UserDataRepository.swift", 160, "DELETE FROM health_profile"),
    ("apps/ios/Platform/Persistence/Repository/UserDataRepository.swift", 161, "DELETE FROM cooking_history"),
]

# (pr_sha, path, line, expected substring) — checked against the PR head file.
PR_REFS: list[tuple[str, str, int, str]] = [
    (PR_13, "apps/ios/Capability/Core/Services/ScanRunStore.swift", 35, "let outcome: ScanOutcome"),
    (PR_13, "apps/ios/Capability/Core/Services/ScanRunStore.swift", 47, "let requestFailures"),
    (PR_13, "apps/ios/Capability/Core/Recognition/ScanContracts.swift", 44, "enum ScanOutcome"),
    (PR_5, "apps/ios/Capability/Core/Services/ReverseScanService.swift", 367, "static func fallbackTemplate"),
    (PR_4, "apps/ios/App/AppDependencies.swift", 137, "kitchenIngredientIDs"),
    (PR_4, "apps/ios/Platform/Persistence/Services/MealLogService.swift", 52, "portionMultiplier"),
]


def current_head() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout.strip()


def read_git_file(sha: str, path: str) -> str:
    return subprocess.run(
        ["git", "show", f"{sha}:{path}"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout


def main() -> int:
    failures: list[str] = []
    head = current_head()

    if head != MAIN_SHA:
        print(f"WARNING: working tree is at {head}, doc audits {MAIN_SHA}.")
        print("Main-branch refs are checked against the working tree; rebase or checkout main to verify them as written.\n")

    for path, line, needle in MAIN_REFS:
        fpath = REPO / path
        try:
            text = fpath.read_text()
        except FileNotFoundError:
            failures.append(f"MISSING FILE  {path}")
            continue
        lines = text.splitlines()
        if len(lines) < line:
            failures.append(f"OUT OF RANGE  {path}:{line} (file has {len(lines)} lines)")
            continue
        if needle not in lines[line - 1]:
            failures.append(
                f"MISMATCH     {path}:{line}\n  expected: {needle!r}\n  actual:   {lines[line - 1].strip()!r}"
            )

    for sha, path, line, needle in PR_REFS:
        try:
            text = read_git_file(sha, path)
        except subprocess.CalledProcessError:
            failures.append(f"UNREADABLE   {sha[:8]}:{path}")
            continue
        lines = text.splitlines()
        if len(lines) < line:
            failures.append(f"OUT OF RANGE  {sha[:8]}:{path}:{line} (file has {len(lines)} lines)")
            continue
        if needle not in lines[line - 1]:
            failures.append(
                f"MISMATCH     {sha[:8]}:{path}:{line}\n  expected: {needle!r}\n  actual:   {lines[line - 1].strip()!r}"
            )

    total = len(MAIN_REFS) + len(PR_REFS)
    if failures:
        print(f"FAILED: {len(failures)}/{total} refs wrong.")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"OK: all {total} refs verified ({len(MAIN_REFS)} on main@{MAIN_SHA[:8]}, {len(PR_REFS)} on PR heads).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
