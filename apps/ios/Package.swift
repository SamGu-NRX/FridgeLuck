// swift-tools-version: 6.0

// Package.swift exists only for lightweight package-based tooling and tests.
// The canonical app project is generated from project.yml into FridgeLuck.xcodeproj.
//
// Linux coverage: the targets below use explicit source lists so exactly the
// Foundation/GRDB-only logic subset of the app compiles, and its tests run,
// on Linux (CI: .github/workflows/linux-swift.yml; boundary: README.md).
// Sources that import UIKit, SwiftUI, Vision, HealthKit, UserNotifications,
// ARKit, ImageIO, or Photos — and the test files that exercise them — are
// intentionally excluded from this package build; they are exercised by the
// hosted iOS job (xcodebuild via project.yml). The exclude lists below pin
// that boundary: every file left out of the sources is named (or covered by a
// whole-directory exclude), so a new UI-coupled file cannot enter silently
// and SwiftPM's unhandled-file warning flags any list that drifts. On Linux
// only, a logging-only `os` shim (LinuxSupport/os) satisfies `import os` for
// files that log through os.Logger. It implements logging exclusively and
// never stands in for functional Apple-framework APIs.

import PackageDescription

// Pure logic extracted under FeatureLogic/. Compiles on iOS and Linux.
// All sources of this target are listed explicitly so a new file that needs
// Apple-only frameworks cannot silently enter the Linux build.
let featureLogicSources: [String] = [
  "AppFlow/AppFlowPolicy.swift",
  "Assistant/LiveAssistantPanelLayout.swift",
  "Benchmark/ScanBenchmarkModels.swift",
  "Benchmark/ScanBenchmarkScoring.swift",
  "Demo/DemoFallbackPolicy.swift",
  "Permissions/AppPermissionCenterMapping.swift",
  "Recipe/CookingGuideStateTransitions.swift",
  "Recipe/CookingGuideSteps.swift",
  "Recipe/CookingLaunchFlow.swift",
  "Recipe/RecipeIngredientMark.swift",
  "Recommendation/RecommendationPolicy.swift",
]

// App sources exercised by the Linux-runnable tests: files importing only
// Foundation, GRDB, FLFeatureLogic, and (for logging) os. Listed explicitly;
// the excluded siblings are enumerated in the exclude list below (the human
// rationale lives in README.md).
let appLogicSources: [String] = [
  "Capability/Core/Recognition/ConfidenceRouter.swift",
  "Capability/Core/Recognition/IngredientIdentityResolution.swift",
  "Capability/Core/Recognition/IngredientLexicon.swift",
  "Capability/Core/Recognition/LearningService.swift",
  "Capability/Core/Recognition/ScanContracts.swift",
  "Domain/Models/DashboardModels.swift",
  "Domain/Models/Detection.swift",
  "Domain/Models/DishTemplate.swift",
  "Domain/Models/HealthProfile.swift",
  "Domain/Models/Ingredient.swift",
  "Domain/Models/IngredientSwap.swift",
  "Domain/Models/Inventory.swift",
  "Domain/Models/NotificationModels.swift",
  "Domain/Models/PantryAssumption.swift",
  "Domain/Models/Recipe.swift",
  "Domain/Models/UserProgress.swift",
  "Feature/Home/HomeDashboardModels.swift",
  "LinuxSupport/AppLogic/LinuxCompatibility.swift",
  "Platform/Persistence/Bundle/BundledDataLoader.swift",
  "Platform/Persistence/Bundle/BundledDataLoaderRecipeHydration.swift",
  "Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift",
  "Platform/Persistence/Database/AppDatabase.swift",
  "Platform/Persistence/Database/Migrations.swift",
  "Platform/Persistence/Repository/IngredientRepository.swift",
  "Platform/Persistence/Repository/InventoryRepository.swift",
  "Platform/Persistence/Repository/NotificationRuleRepository.swift",
  "Platform/Persistence/Repository/RecipeRepository.swift",
  "Platform/Persistence/Repository/RecipeScoring.swift",
  "Platform/Persistence/Repository/UserDataRepository.swift",
  "Platform/Persistence/Services/HealthScoringService.swift",
  "Platform/Persistence/Services/InventoryIntakeService.swift",
  "Platform/Persistence/Services/NutritionService.swift",
  "Platform/Persistence/Services/PersonalizationService.swift",
]

// Every file under the target path that is NOT in appLogicSources, so the
// exclusion boundary is enforced by the manifest itself:
// - whole directories whose files are all UI-coupled or vendor code;
// - individual files in directories that also contain included sources.
// Feature/Home/HomeDashboardModels.swift is included (Foundation-only), so the
// other Home/Feature files are named individually.
let appLogicExclude: [String] = [
  "App",
  "Capability/Core/Intelligence",
  "Capability/Core/Recognition/IngredientCatalogResolver.swift",
  "Capability/Core/Recognition/NutritionLabelParser.swift",
  "Capability/Core/Recognition/ScanBenchmarkRunner.swift",
  "Capability/Core/Recognition/VisionService.swift",
  "Capability/Core/Services",
  "DesignSystem",
  "Domain/Ports",
  "Feature/Assistant",
  "Feature/Demo",
  "Feature/Estimate",
  "Feature/Finalization",
  "Feature/Ingredients",
  "Feature/Inventory",
  "Feature/Kitchen",
  "Feature/Onboarding",
  "Feature/Profile",
  "Feature/Progress",
  "Feature/Recipe",
  "Feature/Results",
  "Feature/Scan",
  "Feature/Settings",
  "Feature/Shared",
  "Feature/Home/HomeActiveStateCard.swift",
  "Feature/Home/HomeAnalyticsSections.swift",
  "Feature/Home/HomeDailyNutritionRing.swift",
  "Feature/Home/HomeDashboardView.swift",
  "Feature/Home/HomeDashboardViewModel.swift",
  "Feature/Home/HomeFallbackOptionsRow.swift",
  "Feature/Home/HomeGraduatedSections.swift",
  "Feature/Home/HomePrimaryRecommendationCard.swift",
  "Feature/Home/HomeTutorialSections.swift",
  "Feature/Home/HomeUseSoonAlert.swift",
  "Feature/Home/SpotlightCoordinator.swift",
  "Feature/Home/SpotlightModels.swift",
  "Feature/Home/SpotlightTutorialOverlay.swift",
  "Feature/Home/TutorialFlowContext.swift",
  "Feature/Home/TutorialProgressView.swift",
  "Feature/Home/TutorialQuestCard.swift",
  "Feature/Home/TutorialQuestModels.swift",
  "FeatureLogic",
  "Integration",
  "README.md",
  "LinuxSupport/os",
  "Platform/Notifications",
  "Platform/Persistence/Services/AppleHealthService.swift",
  "Platform/Persistence/Services/ConfidenceLearningService.swift",
  "Platform/Persistence/Services/DishEstimateService.swift",
  "Platform/Persistence/Services/ImageStorageService.swift",
  "Platform/Persistence/Services/MealLogService.swift",
  "Platform/Persistence/Services/MealLogSyncCoordinator.swift",
  "Platform/Persistence/Services/PantryAssumptionService.swift",
  "Platform/Persistence/Services/SpoilageService.swift",
  "Platform/Persistence/Services/SubstitutionService.swift",
  "Platform/Persistence/Static",
  "Resources",
  "Support",
  "Tests",
  "Vendor",
]

// Test files that compile and run against the logic subset. Files that pull in
// the UIKit/SwiftUI/Vision/HealthKit app surface are deliberately not listed;
// see README.md for the enumerated boundary.
let packageTestSources: [String] = [
  "AppFlowPolicyTests.swift",
  "CookingGuideStateTransitionsTests.swift",
  "CookingGuideStepsTests.swift",
  "CookingLaunchFlowTests.swift",
  "DemoFallbackPolicyTests.swift",
  "GeminiLiveTutorialFlowTests.swift",
  "IngredientIdentityResolutionTests.swift",
  "IngredientLexiconTests.swift",
  "InventoryQuantityEstimateTests.swift",
  "LaunchPerformanceRemediationTests.swift",
  "LiveAssistantPanelLayoutTests.swift",
  "MigrationUpgradeTests.swift",
  "NotificationRuleRepositoryTests.swift",
  "NutritionReportingTests.swift",
  "OnboardingGatePolicyTests.swift",
  "OnboardingPerformanceRemediationTests.swift",
  "PersistenceMappingTests.swift",
  "PersonalizationServiceTests.swift",
  "PortionLoggingTests.swift",
  "RecipeIngredientMarkTests.swift",
  "RecommendationPolicyTests.swift",
  "ScanBenchmarkScorerTests.swift",
  "ScanIntakeReconciliationTests.swift",
  "SettingsTrackingRemindersViewTests.swift",
  "SwapLoggingTests.swift",
]

// Every file under Tests/ that is not in packageTestSources: tests whose
// subjects import SwiftUI, UIKit, Vision, or HealthKit.
let packageTestExclude: [String] = [
  "AppPermissionCenterTests.swift",
  "CaptureLifecycleRegressionTests.swift",
  "HelpTutorialReplayTests.swift",
  "InventoryChangeObservationTests.swift",
  "KitchenLocationOrderTests.swift",
  "KitchenSelectionTests.swift",
  "NotificationCoordinatorTests.swift",
  "NotificationSchedulerTests.swift",
  "RecipeMissingIngredientChipsTests.swift",
  "RecommendationSectionsTests.swift",
  "SettingsFlowTests.swift",
  "SpotlightAnchorUpdateTests.swift",
  "SpotlightScrollMotionTests.swift",
  "SpotlightTourProgressTests.swift",
]

// Linux ships no `os` module, so files that log through os.Logger need the
// logging-only shim. It is wired in on Linux only; on Apple platforms the real
// os framework is used.
#if os(Linux)
let fridgeLuckDependencies: [Target.Dependency] = [
  "FLFeatureLogic",
  "os",
  .product(name: "GRDB", package: "GRDB.swift"),
]
#else
let fridgeLuckDependencies: [Target.Dependency] = [
  "FLFeatureLogic",
  .product(name: "GRDB", package: "GRDB.swift"),
]
#endif

var targets: [Target] = [
  .target(
    name: "FLFeatureLogic",
    path: "FeatureLogic",
    sources: featureLogicSources
  ),
  .target(
    name: "FridgeLuck",
    dependencies: fridgeLuckDependencies,
    path: ".",
    exclude: appLogicExclude,
    sources: appLogicSources
  ),
  .testTarget(
    name: "AppModuleTests",
    dependencies: [
      "FLFeatureLogic",
      "FridgeLuck",
      .product(name: "GRDB", package: "GRDB.swift"),
    ],
    path: "Tests",
    exclude: packageTestExclude,
    sources: packageTestSources
  ),
]

#if os(Linux)
targets.append(
  .target(
    name: "os",
    path: "LinuxSupport/os"
  )
)
#endif

let package = Package(
  name: "FridgeLuck",
  platforms: [
    .iOS("26.0")
  ],
  products: [
    .library(
      name: "FLFeatureLogic",
      targets: ["FLFeatureLogic"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: targets
)
