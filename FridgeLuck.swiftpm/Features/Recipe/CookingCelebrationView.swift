import SwiftUI
import UIKit

/// Post-cooking celebration screen. Shows confetti, macro breakdown, serving adjuster,
/// star rating, and photo capture. Records the cooking event when the user taps "Done".
struct CookingCelebrationView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  var onDismiss: () -> Void

  // MARK: - State

  @State private var servings: Int = 1
  @State private var rating: Int = 0
  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var healthProfile: HealthProfile = .default
  @State private var appeared = false
  @State private var showConfetti = true
  @State private var isSaving = false

  private var recipe: Recipe { scoredRecipe.recipe }
  private var baseMacros: RecipeMacros { scoredRecipe.macros }

  // MARK: - Scaled macros

  private var scaledCalories: Double { baseMacros.caloriesPerServing * Double(servings) }
  private var scaledProtein: Double { baseMacros.proteinPerServing * Double(servings) }
  private var scaledCarbs: Double { baseMacros.carbsPerServing * Double(servings) }
  private var scaledFat: Double { baseMacros.fatPerServing * Double(servings) }

  // MARK: - Daily goal percentages

  private var dailyCalories: Double {
    Double(healthProfile.dailyCalories ?? healthProfile.goal.suggestedCalories)
  }

  private var dailyProteinGrams: Double {
    (dailyCalories * healthProfile.proteinPct) / 4.0  // 4 kcal per gram
  }

  private var dailyCarbsGrams: Double {
    (dailyCalories * healthProfile.carbsPct) / 4.0
  }

  private var dailyFatGrams: Double {
    (dailyCalories * healthProfile.fatPct) / 9.0  // 9 kcal per gram
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

  // MARK: - Body

  var body: some View {
    ZStack {
      AppTheme.bg.ignoresSafeArea()

      ScrollView {
        VStack(spacing: AppTheme.Space.lg) {
          headerSection
          servingSection
          macroSection
          ratingSection
          photoSection
          doneButton
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.xl)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }

      // Confetti overlay
      if showConfetti {
        ConfettiOverlay {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            showConfetti = false
          }
        }
      }
    }
    .task {
      servings = recipe.servings
      loadHealthProfile()
      if !reduceMotion {
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(AppMotion.celebration) {
          appeared = true
        }
      } else {
        appeared = true
      }
    }
    .sheet(isPresented: $showCamera) {
      MealPhotoPicker(image: $capturedImage)
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "frying.pan.fill")
        .font(.system(size: 44))
        .foregroundStyle(AppTheme.accent)
        .scaleEffect(appeared ? 1 : 0.5)
        .opacity(appeared ? 1 : 0)

      Text("Well Done!")
        .font(AppTheme.Typography.displayLarge)
        .foregroundStyle(AppTheme.textPrimary)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)

      Text(recipe.title)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }
    .padding(.bottom, AppTheme.Space.sm)
  }

  // MARK: - Serving Adjuster

  private var servingSection: some View {
    FLCard(tone: .warm) {
      FLServingStepper(servings: $servings, label: "Servings eaten")
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.06), value: appeared)
  }

  // MARK: - Macro Breakdown

  private var macroSection: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        FLSectionHeader("Nutrition", icon: "chart.pie.fill")

        // Macro ring + calorie center
        HStack(spacing: AppTheme.Space.lg) {
          ZStack {
            FLMacroRing(
              proteinPct: baseMacros.macroSplit.proteinPct,
              carbsPct: baseMacros.macroSplit.carbsPct,
              fatPct: baseMacros.macroSplit.fatPct,
              size: 100,
              lineWidth: 10
            )

            VStack(spacing: 2) {
              Text("\(Int(scaledCalories.rounded()))")
                .font(AppTheme.Typography.dataMedium)
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
              Text("kcal")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }

          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            macroRow(
              label: "Protein",
              grams: scaledProtein,
              pctOfDaily: proteinPct,
              color: AppTheme.sage
            )
            macroRow(
              label: "Carbs",
              grams: scaledCarbs,
              pctOfDaily: carbsPct,
              color: AppTheme.oat
            )
            macroRow(
              label: "Fat",
              grams: scaledFat,
              pctOfDaily: fatPct,
              color: AppTheme.accentLight
            )
          }
        }

        // Calorie % of daily goal
        VStack(spacing: AppTheme.Space.xxs) {
          HStack {
            Text("Daily calorie goal")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("\(Int((caloriePct * 100).rounded()))%")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.accent)
              .contentTransition(.numericText())
          }
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(AppTheme.surfaceMuted)
              Capsule()
                .fill(AppTheme.accent)
                .frame(width: geo.size.width * caloriePct)
                .animation(reduceMotion ? nil : AppMotion.counterReveal, value: caloriePct)
            }
          }
          .frame(height: 6)
        }
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.12), value: appeared)
  }

  private func macroRow(
    label: String, grams: Double, pctOfDaily: Double, color: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      HStack {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)
        Text(label)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text("\(Int(grams.rounded()))g")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())
      }
      // Mini progress bar for % of daily goal
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(color.opacity(0.15))
          Capsule()
            .fill(color)
            .frame(width: geo.size.width * pctOfDaily)
            .animation(reduceMotion ? nil : AppMotion.counterReveal, value: pctOfDaily)
        }
      }
      .frame(height: 4)
    }
  }

  // MARK: - Star Rating

  private var ratingSection: some View {
    FLCard(tone: .warm) {
      VStack(spacing: AppTheme.Space.sm) {
        Text("How was it?")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        FLStarRating(rating: $rating, size: 32)

        if rating > 0 {
          Text(ratingLabel)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      }
      .frame(maxWidth: .infinity)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.18), value: appeared)
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

  // MARK: - Photo Capture

  private var photoSection: some View {
    Group {
      if let capturedImage {
        // Show captured photo
        FLCard {
          VStack(spacing: AppTheme.Space.sm) {
            Image(uiImage: capturedImage)
              .resizable()
              .scaledToFill()
              .frame(height: 200)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

            HStack {
              Text("Photo saved")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.positive)

              Spacer()

              Button {
                self.capturedImage = nil
              } label: {
                Text("Retake")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.accent)
              }
            }
          }
        }
      } else {
        // Photo CTA
        Button {
          showCamera = true
        } label: {
          HStack(spacing: AppTheme.Space.sm) {
            Image(systemName: "camera.fill")
              .font(.system(size: 18))
              .foregroundStyle(AppTheme.accent)

            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text("Take a Photo")
                .font(AppTheme.Typography.bodyLarge)
                .foregroundStyle(AppTheme.textPrimary)
              Text("Capture your creation for your cooking journal")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(AppTheme.textSecondary)
          }
          .padding(AppTheme.Space.md)
          .background(
            AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              .stroke(
                AppTheme.oat.opacity(0.35),
                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
              )
          )
        }
        .buttonStyle(FLPressableButtonStyle())
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.24), value: appeared)
  }

  // MARK: - Done Button

  private var doneButton: some View {
    FLPrimaryButton("Done", systemImage: "checkmark", isEnabled: !isSaving) {
      Task { await saveAndDismiss() }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.30), value: appeared)
    .padding(.top, AppTheme.Space.sm)
  }

  // MARK: - Actions

  private func loadHealthProfile() {
    healthProfile = (try? deps.userDataRepository.fetchHealthProfile()) ?? .default
  }

  private func saveAndDismiss() async {
    guard !isSaving else { return }
    isSaving = true

    // Save photo if captured
    var imagePath: String?
    if let image = capturedImage {
      imagePath = try? deps.imageStorageService.save(image)
    }

    // Record cooking event
    if let recipeId = recipe.id {
      try? deps.personalizationService.recordCooking(
        recipeId: recipeId,
        rating: rating > 0 ? rating : nil,
        imagePath: imagePath,
        servingsConsumed: servings
      )
    }

    onDismiss()
  }
}

// MARK: - Meal Photo Picker

/// A simple camera/photo picker for meal photos. Unlike `CameraPicker`, this does NOT
/// apply `ScanImagePreprocessor` since we want the original photo for the food journal.
private struct MealPhotoPicker: UIViewControllerRepresentable {
  @Binding var image: UIImage?
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.delegate = context.coordinator
    picker.modalPresentationStyle = .fullScreen
    picker.allowsEditing = true

    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      picker.sourceType = .camera
    } else {
      picker.sourceType = .photoLibrary
    }

    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let parent: MealPhotoPicker

    init(_ parent: MealPhotoPicker) {
      self.parent = parent
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
        parent.image = image  // No preprocessing — keep the original meal photo
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}

// MARK: - FLPressableButtonStyle (private access bridge)

/// Re-exported for use in this file's photo button.
private struct FLPressableButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: configuration.isPressed)
  }
}
