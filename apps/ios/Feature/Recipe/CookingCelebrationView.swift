import PhotosUI
import SwiftUI
import UIKit

/// Post-cooking celebration screen. Shows confetti, macro breakdown, serving adjuster,
/// star rating, and photo capture. Records the cooking event when the user taps "Done".
struct CookingCelebrationView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  private let scopedDependencies: Dependencies?
  var onDismiss: () -> Void

  struct Dependencies {
    let fetchHealthProfile: () throws -> HealthProfile
    let logMeal:
      (_ recipe: Recipe, _ rating: Int?, _ capturedImage: UIImage?, _ servings: Int) throws ->
        MealLogService.Outcome
  }

  init(
    scoredRecipe: ScoredRecipe,
    dependencies: Dependencies? = nil,
    onDismiss: @escaping () -> Void
  ) {
    self.scoredRecipe = scoredRecipe
    self.scopedDependencies = dependencies
    self.onDismiss = onDismiss
  }

  @State private var servings: Int = 1
  @State private var rating: Int = 0
  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var cameraPermissionStatus: AppPermissionStatus = .notDetermined
  @State private var healthProfile: HealthProfile = .default
  @State private var appeared = false
  @State private var showConfetti = true
  @State private var isSaving = false
  @State private var showRatingNudge = false
  @State private var showSaveError = false

  private var recipe: Recipe { scoredRecipe.recipe }
  private var baseMacros: RecipeMacros { scoredRecipe.macros }
  private var dependencies: Dependencies {
    if let scopedDependencies { return scopedDependencies }
    return Dependencies(
      fetchHealthProfile: { try deps.userDataRepository.fetchHealthProfile() },
      logMeal: { recipe, rating, capturedImage, servings in
        try deps.mealLogService.logMeal(
          recipe: recipe,
          rating: rating,
          capturedImage: capturedImage,
          servingsConsumed: servings,
          sourceRefPrefix: "cooking_celebration"
        )
      }
    )
  }

  private var scaledCalories: Double { baseMacros.caloriesPerServing * Double(servings) }
  private var scaledProtein: Double { baseMacros.proteinPerServing * Double(servings) }
  private var scaledCarbs: Double { baseMacros.carbsPerServing * Double(servings) }
  private var scaledFat: Double { baseMacros.fatPerServing * Double(servings) }

  private var dailyCalories: Double {
    Double(healthProfile.dailyCalories ?? healthProfile.goal.suggestedCalories)
  }

  private var dailyProteinGrams: Double {
    (dailyCalories * healthProfile.proteinPct) / 4.0
  }

  private var dailyCarbsGrams: Double {
    (dailyCalories * healthProfile.carbsPct) / 4.0
  }

  private var dailyFatGrams: Double {
    (dailyCalories * healthProfile.fatPct) / 9.0
  }

  private var caloriePct: Double {
    guard dailyCalories > 0 else { return 0 }
    return min(scaledCalories / dailyCalories, 1.0)
  }

  private var proteinPct: Double {
    guard dailyProteinGrams > 0 else { return 0 }
    return min(scaledProtein / dailyProteinGrams, 1.0)
  }

  private var carbsPct: Double {
    guard dailyCarbsGrams > 0 else { return 0 }
    return min(scaledCarbs / dailyCarbsGrams, 1.0)
  }

  private var fatPct: Double {
    guard dailyFatGrams > 0 else { return 0 }
    return min(scaledFat / dailyFatGrams, 1.0)
  }

  var body: some View {
    ZStack {
      AppTheme.bg.ignoresSafeArea()

      ScrollView {
        VStack(spacing: AppTheme.Space.lg) {
          CookingCelebrationHeaderSection(appeared: appeared, recipeTitle: recipe.title)

          CookingCelebrationRatingSection(
            rating: $rating,
            ratingLabel: ratingLabel,
            appeared: appeared,
            reduceMotion: reduceMotion
          )

          CookingCelebrationServingSection(
            servings: $servings,
            appeared: appeared,
            reduceMotion: reduceMotion
          )

          CookingCelebrationMacroSection(
            baseMacros: baseMacros,
            scaledCalories: scaledCalories,
            scaledProtein: scaledProtein,
            scaledCarbs: scaledCarbs,
            scaledFat: scaledFat,
            caloriePct: caloriePct,
            proteinPct: proteinPct,
            carbsPct: carbsPct,
            fatPct: fatPct,
            appeared: appeared,
            reduceMotion: reduceMotion
          )

          CookingCelebrationPhotoSection(
            capturedImage: $capturedImage,
            cameraPermissionStatus: cameraPermissionStatus,
            onOpenCamera: openCamera,
            onOpenLibrary: openLibrary,
            onOpenSettings: openSettings,
            appeared: appeared,
            reduceMotion: reduceMotion
          )

          doneButton
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.xl)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }

      if showConfetti {
        ConfettiOverlay {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            showConfetti = false
          }
        }
      }
    }
    .task {
      servings = 1
      loadHealthProfile()
      if !reduceMotion {
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(AppMotion.celebration) {
          appeared = true
        }
      } else {
        appeared = true
      }
      refreshCameraPermissionStatus()
    }
    .sheet(isPresented: $showCamera) {
      MealPhotoPicker(image: $capturedImage)
    }
    .photosPicker(
      isPresented: $showPhotoPicker,
      selection: $selectedPhotoItem,
      matching: .images
    )
    .onChange(of: selectedPhotoItem) { _, newValue in
      guard newValue != nil else { return }
      loadSelectedPhoto()
    }
  }

  private var ratingLabel: String {
    switch rating {
    case 1: return "Not great"
    case 2: return "It was okay"
    case 3: return "Pretty good"
    case 4: return "Really good!"
    case 5: return "Amazing!"
    default: return ""
    }
  }

  private var doneButton: some View {
    FLPrimaryButton("Done", systemImage: "checkmark", isEnabled: !isSaving) {
      if rating == 0 {
        showRatingNudge = true
      } else {
        Task { await saveAndDismiss() }
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.30), value: appeared)
    .padding(.top, AppTheme.Space.sm)
    .alert("Rate this recipe?", isPresented: $showRatingNudge) {
      Button("Skip", role: .cancel) {
        Task { await saveAndDismiss() }
      }
      Button("Rate It") {
      }
    } message: {
      Text(
        "Your ratings help FridgeLuck recommend better recipes next time. It only takes a second!")
    }
    .alert("Couldn't save", isPresented: $showSaveError) {
      Button("Try Again") {
        Task { await saveAndDismiss() }
      }
      Button("Skip", role: .destructive) {
        onDismiss()
      }
    } message: {
      Text("Your meal couldn't be saved to the recipe book. You can try again or skip for now.")
    }
  }

  private func loadHealthProfile() {
    healthProfile = (try? dependencies.fetchHealthProfile()) ?? .default
  }

  private func refreshCameraPermissionStatus() {
    cameraPermissionStatus = AppPermissionCenter.status(for: .camera)
  }

  private func openCamera() {
    Task {
      let result = await AppPermissionCenter.request(.camera)
      if AppPermissionCenter.canProceed(result) {
        cameraPermissionStatus = .authorized
        showCamera = true
        return
      }

      cameraPermissionStatus = AppPermissionCenter.status(for: .camera)
      if cameraPermissionStatus == .unavailable {
        openLibrary()
      }
    }
  }

  private func openLibrary() {
    showPhotoPicker = true
  }

  private func openSettings() {
    AppPermissionCenter.openAppSettings()
  }

  private func loadSelectedPhoto() {
    guard let selectedPhotoItem else { return }

    Task {
      defer { self.selectedPhotoItem = nil }

      do {
        guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
          let image = UIImage(data: data)
        else { return }

        capturedImage = image
      } catch {
        #if DEBUG
          print("[CookingCelebrationView] Failed to load selected photo: \(error)")
        #endif
      }
    }
  }

  private func saveAndDismiss() async {
    guard !isSaving else { return }
    isSaving = true

    do {
      let mealOutcome = try dependencies.logMeal(
        recipe,
        rating > 0 ? rating : nil,
        capturedImage,
        servings
      )
      await deps.mealLogSyncCoordinator.syncLoggedMeal(
        historyId: mealOutcome.historyId,
        recipeId: mealOutcome.recipeId,
        mealTitle: recipe.title,
        servingsConsumed: servings
      )
    } catch {
      #if DEBUG
        print("[CookingCelebrationView] Failed to save cooked meal: \(error)")
      #endif
      isSaving = false
      showSaveError = true
      return
    }

    onDismiss()
  }
}
