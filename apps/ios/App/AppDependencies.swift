import Foundation
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

  let learningService: LearningService
  let ingredientCatalogResolver: IngredientCatalogResolving
  let visionService: VisionService

  let nutritionService: NutritionService
  let healthScoringService: HealthScoringService
  let appleHealthService: AppleHealthServicing
  let appleHealthAuthorizationContext: AppleHealthAuthorizationContext?
  let mealLogSyncCoordinator: MealLogSyncCoordinator
  let personalizationService: PersonalizationService
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

  let recipeGenerator: RecipeGenerating

  init(appDatabase: AppDatabase) {
    self.appDatabase = appDatabase
    let db = appDatabase.dbQueue

    self.nutritionService = NutritionService(db: db)
    self.personalizationService = PersonalizationService(db: db)
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
    self.spoilageService = SpoilageService(inventoryRepository: inventoryRepository)
    self.inventoryIntakeService = InventoryIntakeService(
      ingredientRepository: ingredientRepository,
      inventoryRepository: inventoryRepository
    )
    self.geminiCloudAgent = GeminiCloudAgent()

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
  }

  func makeRecommendationEngine() -> RecommendationEngine {
    RecommendationEngine(
      recipeRepository: recipeRepository,
      healthScoringService: healthScoringService,
      recipeGenerator: recipeGenerator,
      geminiCloudAgent: geminiCloudAgent,
      confidenceLearningService: confidenceLearningService
    )
  }
}
