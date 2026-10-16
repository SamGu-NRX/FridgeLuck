import Foundation
import FLFeatureLogic
import GRDB

#if canImport(HealthKit)
  import HealthKit
#endif

/// Dependency injection container. Created once at app launch.
/// All services share the same DatabaseQueue.
@MainActor
final class AppDependencies: ObservableObject {
  let appDatabase: AppDatabase

  let recipeRepository: RecipeRepository
  let ingredientRepository: IngredientRepository
  let inventoryRepository: InventoryRepository
  let userDataRepository: UserDataRepository
  let notificationRuleRepository: NotificationRuleRepository

  let learningService: LearningService
  let ingredientCatalogResolver: IngredientCatalogResolving
  let visionService: VisionService

  let nutritionService: NutritionService
  let healthScoringService: HealthScoringService
  let appleHealthService: AppleHealthServicing
  let appleHealthAuthorizationContext: AppleHealthAuthorizationContext?
  let mealLogSyncCoordinator: MealLogSyncCoordinator
  let personalizationService: PersonalizationService
  let tasteResidualRanking: TasteResidualRankingService
  let dishEstimateService: DishEstimateService
  let imageStorageService: ImageStorageService
  let scanRunStore: ScanRunStore
  let substitutionService: SubstitutionService
  let spoilageService: SpoilageService
  let inventoryIntakeService: InventoryIntakeService
  let mealLogService: MealLogService
  let confidenceLearningService: ConfidenceLearningService
  let reverseScanService: ReverseScanService
  let geminiCloudAgent: GeminiCloudAgent
  let notificationPermissionService: NotificationPermissionService
  let notificationSyncService: NotificationSyncService
  let notificationCoordinator: NotificationCoordinator

  let recipeGenerator: RecipeGenerating

  // Community client (PRs #159/#166/#173/#179): the packet ships the contract models,
  // API client, session service, store, outbox, and view models — no app construction
  // site referenced them. Built here once at launch so the real app can use the path.
  let communityStore: CommunityStore
  let communitySessionService: CommunitySessionService
  let communitySessionViewModel: SessionViewModel
  let communityTablesViewModel: TablesViewModel
  let communityChallengesViewModel: ChallengesViewModel

  // Taste profile (PRs #165/#167/#176): the repository reads the same event log and
  // the same shipped-bundle feature index the residual ranker uses, so profile
  // evidence resolves on canonical keys. The screen's view model is built from it
  // on demand (the profile page is a push-in screen; its view model exists but no
  // view constructed it before this join).
  let tasteProfileRepository: TasteProfileRepository

  private let tasteCatalogFeatureIndex: TasteCatalogFeatureIndex

  init(appDatabase: AppDatabase) {
    self.appDatabase = appDatabase
    let db = appDatabase.dbQueue

    self.nutritionService = NutritionService(db: db)
    let personalizationService = PersonalizationService(db: db)
    self.personalizationService = personalizationService
    // The taste feature index reads the shipped bundle at launch; the database
    // bridges (legacy successor links) are a single read. A missing or failed
    // index degrades to an empty one — the learned layer then no-ops and the
    // profile falls back to legacy feature tables. One index serves both the
    // residual ranker and the taste profile repository (PR #176).
    let tasteCatalogFeatureIndex = TasteCatalogFeatureIndex.bundled()
      .withDatabaseBridges(dbQueue: db)
    self.tasteCatalogFeatureIndex = tasteCatalogFeatureIndex
    self.tasteResidualRanking = TasteResidualRankingService(
      store: TasteEventStore(db: db),
      personalization: personalizationService,
      catalogIndex: tasteCatalogFeatureIndex)
    self.tasteProfileRepository = TasteProfileRepository(
      dbQueue: db,
      store: TasteEventStore(db: db),
      catalogIndex: tasteCatalogFeatureIndex)
    self.learningService = LearningService(db: db)
    self.ingredientCatalogResolver = IngredientCatalogResolver(db: db)
    let appleHealthService = AppleHealthService()
    self.appleHealthService = appleHealthService
    #if canImport(HealthKit)
      self.appleHealthAuthorizationContext = appleHealthService.authorizationContext
    #else
      self.appleHealthAuthorizationContext = nil
    #endif

    self.healthScoringService = HealthScoringService(
      nutritionService: nutritionService,
      db: db
    )
    self.mealLogSyncCoordinator = MealLogSyncCoordinator(
      appleHealthService: self.appleHealthService,
      nutritionService: nutritionService
    )
    self.dishEstimateService = DishEstimateService(db: db)
    self.imageStorageService = ImageStorageService()
    self.scanRunStore = ScanRunStore()
    self.substitutionService = SubstitutionService(db: db)
    self.confidenceLearningService = ConfidenceLearningService(db: db)

    self.ingredientRepository = IngredientRepository(db: db)
    self.inventoryRepository = InventoryRepository(db: db)
    self.userDataRepository = UserDataRepository(db: db)
    self.notificationRuleRepository = NotificationRuleRepository(db: db)
    self.spoilageService = SpoilageService(inventoryRepository: inventoryRepository)
    self.inventoryIntakeService = InventoryIntakeService(
      ingredientRepository: ingredientRepository,
      inventoryRepository: inventoryRepository
    )
    self.geminiCloudAgent = GeminiCloudAgent()
    self.notificationPermissionService = NotificationPermissionService()
    self.notificationSyncService = NotificationSyncService()
    self.notificationCoordinator = NotificationCoordinator(
      ruleRepository: notificationRuleRepository,
      permissionService: notificationPermissionService,
      scheduler: NotificationScheduler(),
      syncService: notificationSyncService,
      inventoryRepository: inventoryRepository,
      spoilageService: spoilageService
    )

    self.recipeRepository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoringService,
      personalizationService: personalizationService
    )
    self.mealLogService = MealLogService(
      db: db,
      recipeRepository: recipeRepository,
      personalizationService: personalizationService,
      inventoryRepository: inventoryRepository,
      imageStorageService: imageStorageService
    )

    self.visionService = VisionService(
      learningService: learningService,
      ingredientResolver: ingredientCatalogResolver
    )
    self.reverseScanService = ReverseScanService(
      visionService: visionService,
      recipeRepository: recipeRepository,
      healthScoringService: healthScoringService,
      dishEstimateService: dishEstimateService,
      geminiCloudAgent: geminiCloudAgent,
      confidenceLearningService: confidenceLearningService
    )

    self.recipeGenerator = RecipeGeneratorFactory.create(
      recipeRepository: recipeRepository,
      ingredientResolver: ingredientCatalogResolver
    )

    // Community stack. The session service defaults to the local dev backend
    // (`backend/community`, default port 8087); deployments override it with the
    // COMMUNITY_BACKEND_BASE_URL environment or Info.plist value.
    let communityStore = CommunityStore(db: db)
    self.communityStore = communityStore
    let communitySessionService = CommunitySessionService(
      baseURL: Self.communityBackendBaseURL,
      tokenStore: KeychainCommunityTokenStore(service: "samgu.FridgeLuck.community"))
    self.communitySessionService = communitySessionService
    let sessionViewModel = SessionViewModel(service: communitySessionService)
    self.communitySessionViewModel = sessionViewModel
    self.communityTablesViewModel = TablesViewModel(
      client: communitySessionService.client,
      store: communityStore,
      session: sessionViewModel)
    self.communityChallengesViewModel = ChallengesViewModel(
      client: communitySessionService.client)
  }

  /// The community backend base URL (version prefix included, per the client's
  /// contract). Environment first, then Info.plist, then the local dev server.
  static var communityBackendBaseURL: URL {
    let env = ProcessInfo.processInfo.environment["COMMUNITY_BACKEND_BASE_URL"]
      ?? Bundle.main.object(forInfoDictionaryKey: "COMMUNITY_BACKEND_BASE_URL") as? String
    guard let raw = env, let url = URL(string: raw) else {
      return URL(string: "http://127.0.0.1:8087/v1")!
    }
    return url
  }

  /// The taste profile page's view model (docs/spec/taste/SPEC.md §4): sentences with
  /// their evidence plus the correction actions. Building it here (not at launch) keeps
  /// the profile a pull — the page loads when opened.
  func makeTasteProfileViewModel() -> TasteProfileViewModel {
    TasteProfileViewModel(service: tasteProfileRepository)
  }

  /// The LeChef plan sheet's view model (PRs #152/#178): one allocator over the shared
  /// database, reading the snapshot through the production adapter — legacy and catalog
  /// candidates, stock pool, allergen screening, weekly horizon. No view constructs the
  /// sheet yet; the view model is the wiring seam.
  func makePlanSheetViewModel(now: Date = Date()) -> PlanSheetViewModel {
    let dbQueue = appDatabase.dbQueue
    return PlanSheetViewModel(now: now) { query in
      try PlanDataAdapter(dbQueue: dbQueue, now: query.now).loadSnapshot()
    }
  }

  func makeRecommendationEngine() -> RecommendationEngine {
    RecommendationEngine(
      recipeRepository: recipeRepository,
      healthScoringService: healthScoringService,
      recipeGenerator: recipeGenerator,
      geminiCloudAgent: geminiCloudAgent,
      confidenceLearningService: confidenceLearningService,
      kitchenIngredientIDs: { [inventoryRepository] in
        Set(try inventoryRepository.fetchAllActiveItems().map(\.ingredientId))
      }
    )
  }
}
