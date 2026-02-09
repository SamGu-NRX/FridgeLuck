import Foundation
import GRDB

/// Dependency injection container. Created once at app launch.
/// All services share the same DatabaseQueue.
@MainActor
final class AppDependencies: ObservableObject {
  // Database
  let appDatabase: AppDatabase

  // Repositories
  let recipeRepository: RecipeRepository
  let ingredientRepository: IngredientRepository
  let userDataRepository: UserDataRepository

  // Recognition
  let learningService: LearningService
  let visionService: VisionService

  // Services
  let nutritionService: NutritionService
  let healthScoringService: HealthScoringService
  let personalizationService: PersonalizationService

  // Intelligence
  let recipeGenerator: RecipeGenerating

  init(appDatabase: AppDatabase) {
    self.appDatabase = appDatabase
    let db = appDatabase.dbQueue

    // Services (no dependencies on each other)
    self.nutritionService = NutritionService(db: db)
    self.personalizationService = PersonalizationService(db: db)
    self.learningService = LearningService(db: db)

    // Health scoring depends on nutrition service
    self.healthScoringService = HealthScoringService(
      nutritionService: nutritionService,
      db: db
    )

    // Repositories
    self.ingredientRepository = IngredientRepository(db: db)
    self.userDataRepository = UserDataRepository(db: db)

    self.recipeRepository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoringService,
      personalizationService: personalizationService
    )

    // Recognition
    self.visionService = VisionService(learningService: learningService)

    // Intelligence (uses fallback until iOS 26 SDK is available)
    self.recipeGenerator = RecipeGeneratorFactory.create(
      recipeRepository: recipeRepository
    )
  }
}
