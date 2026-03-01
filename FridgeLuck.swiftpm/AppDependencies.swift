import Foundation
import GRDB

/// Dependency injection container. Created once at app launch.
/// All services share the same DatabaseQueue.
@MainActor
final class AppDependencies: ObservableObject {
  let appDatabase: AppDatabase

  let recipeRepository: RecipeRepository
  let ingredientRepository: IngredientRepository
  let userDataRepository: UserDataRepository

  let learningService: LearningService
  let ingredientCatalogResolver: IngredientCatalogResolving
  let visionService: VisionService

  let nutritionService: NutritionService
  let healthScoringService: HealthScoringService
  let personalizationService: PersonalizationService
  let dishEstimateService: DishEstimateService
  let imageStorageService: ImageStorageService
  let scanRunStore: ScanRunStore
  let substitutionService: SubstitutionService

  let recipeGenerator: RecipeGenerating

  init(appDatabase: AppDatabase) {
    self.appDatabase = appDatabase
    let db = appDatabase.dbQueue

    self.nutritionService = NutritionService(db: db)
    self.personalizationService = PersonalizationService(db: db)
    self.learningService = LearningService(db: db)
    self.ingredientCatalogResolver = IngredientCatalogResolver(db: db)

    self.healthScoringService = HealthScoringService(
      nutritionService: nutritionService,
      db: db
    )
    self.dishEstimateService = DishEstimateService(db: db)
    self.imageStorageService = ImageStorageService()
    self.scanRunStore = ScanRunStore()
    self.substitutionService = SubstitutionService(db: db)

    self.ingredientRepository = IngredientRepository(db: db)
    self.userDataRepository = UserDataRepository(db: db)

    self.recipeRepository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoringService,
      personalizationService: personalizationService
    )

    self.visionService = VisionService(
      learningService: learningService,
      ingredientResolver: ingredientCatalogResolver
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
      recipeGenerator: recipeGenerator
    )
  }
}
