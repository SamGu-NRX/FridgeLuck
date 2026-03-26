import PhotosUI
import SwiftUI
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ReverseScanMealView")

/// Multi-step reverse-scan flow for prepared meals.
///
/// Stage 1: Capture — open camera or photo library
/// Stage 2: Analyze — scan sweep animation + recipe matching
/// Stage 3: Results — recipe candidates, macros, confirm & log
struct ReverseScanMealView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - Stage Model

  private enum ScanStage: Int {
    case capture = 1
    case analyze = 2
    case results = 3
  }

  // MARK: - State

  @State private var capturedImage: UIImage?
  @State private var showCamera = false
  @State private var showPhotoPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var isAnalyzing = false
  @State private var analysis: ReverseScanAnalysis?
  @State private var selectedCandidateID: Int64?
  @State private var servings: Int = 1
  @State private var portionSize: DishPortionSize = .normal
  @State private var errorMessage: String?
  @State private var isLoggingMeal = false
  @State private var showLogSuccess = false
  @State private var showRecipePicker = false
  @State private var cameraPermissionStatus: AppPermissionStatus = .notDetermined
  @State private var manuallyPickedRecipe: Recipe?
  @State private var manuallyPickedMacros: RecipeMacros?
  @State private var resultsAppeared = false

  // MARK: - Derived

  private var stage: ScanStage {
    if isAnalyzing { return .analyze }
    if analysis != nil || errorMessage != nil { return .results }
    return .capture
  }

  private var stageProgress: Double {
    Double(stage.rawValue) / 3.0
  }

  private var stageName: String {
    switch stage {
    case .capture: return "Capture"
    case .analyze: return "Analyzing"
    case .results: return "Results"
    }
  }

  private var selectedCandidate: ReverseScanRecipeCandidate? {
    guard let analysis else { return nil }
    if let selectedCandidateID,
      let selected = analysis.candidateRecipes.first(where: { $0.id == selectedCandidateID })
    {
      return selected
    }
    return analysis.candidateRecipes.first
  }

  private var fallbackEstimate: PreparedDishEstimate? {
    guard let template = analysis?.fallbackTemplate else { return nil }
    return deps.dishEstimateService.estimate(template: template, size: portionSize)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      ScanArcStageIndicator(
        stageProgress: stageProgress,
        stageName: stageName,
        stageIndex: stage.rawValue,
        reduceMotion: reduceMotion
      )
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.lg)

      ZStack {
        Group {
          switch stage {
          case .capture:
            captureStageView
          case .analyze:
            analyzingStageView
          case .results:
            resultsStageView
          }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(reduceMotion ? nil : AppMotion.gentle, value: stage.rawValue)
    }
    .padding(.horizontal, AppTheme.Space.page)
    .navigationTitle("Log a Meal")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .sheet(isPresented: $showCamera) {
      CameraPicker(image: $capturedImage)
        .ignoresSafeArea()
    }
    .photosPicker(
      isPresented: $showPhotoPicker,
      selection: $selectedPhotoItem,
      matching: .images
    )
    .sheet(isPresented: $showRecipePicker) {
      RecipePickerView(
        analysis: analysis,
        onSelect: { recipe, macros in
          manuallyPickedRecipe = recipe
          manuallyPickedMacros = macros
          selectedCandidateID = nil
        }
      )
      .environmentObject(deps)
    }
    .alert("Meal logged", isPresented: $showLogSuccess) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Your meal has been recorded and inventory updated.")
    }
    .onAppear {
      cameraPermissionStatus = AppPermissionCenter.status(for: .camera)
    }
    .onChange(of: capturedImage) { _, newValue in
      guard newValue != nil else { return }
      Task { await analyze() }
    }
    .onChange(of: selectedPhotoItem) { _, newValue in
      guard newValue != nil else { return }
      loadSelectedPhoto()
    }
  }

  // MARK: - Stage 1: Capture

  private var captureStageView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer(minLength: AppTheme.Space.md)

      Image(systemName: "camera.macro")
        .font(.system(size: 72, weight: .thin))
        .foregroundStyle(AppTheme.accent.opacity(0.7))
        .padding(AppTheme.Space.xl)
        .background(
          Circle()
            .fill(AppTheme.accent.opacity(0.06))
            .frame(width: 160, height: 160)
        )

      VStack(spacing: AppTheme.Space.sm) {
        Text("Photograph your meal")
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text("A clear photo of your plated meal helps identify the recipe and calculate macros.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLPrimaryButton("Open Camera", systemImage: "camera.fill", action: openCamera)
        FLSecondaryButton(
          "Choose from Library", systemImage: "photo.on.rectangle", action: openLibrary)
      }

      if cameraPermissionStatus == .denied || cameraPermissionStatus == .restricted {
        FLCard(tone: .warning) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Camera permission is off")
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Use photo library to continue without camera access.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: AppTheme.Space.sm) {
              FLSecondaryButton(
                "Use Library", systemImage: "photo.on.rectangle", action: openLibrary)
              FLSecondaryButton(
                "Open Settings", systemImage: "gearshape", action: openSettings)
            }
          }
        }
      }

      if cameraPermissionStatus == .unavailable {
        Text("Camera unavailable on this device. Use the photo library instead.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Stage 2: Analyzing

  private var analyzingStageView: some View {
    ScanAnalyzingView(
      capturedImage: capturedImage,
      fallbackStateText: nil,
      reduceMotion: reduceMotion,
      title: "Analyzing your meal",
      subtitle: "Matching ingredients to recipes in your cookbook."
    )
  }

  // MARK: - Stage 3: Results

  @ViewBuilder
  private var resultsStageView: some View {
    if let errorMessage, analysis == nil {
      errorResultView(errorMessage)
    } else if let analysis {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          // Captured image thumbnail
          if let capturedImage {
            Image(uiImage: capturedImage)
              .resizable()
              .scaledToFill()
              .frame(height: 180)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                  .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
              )
              .opacity(resultsAppeared ? 1 : 0)
              .offset(y: resultsAppeared ? 0 : 12)
              .animation(
                reduceMotion ? nil : AppMotion.cardSpring,
                value: resultsAppeared
              )
          }

          // Detection summary
          detectionSummarySection(analysis)
            .opacity(resultsAppeared ? 1 : 0)
            .offset(y: resultsAppeared ? 0 : 12)
            .animation(
              reduceMotion
                ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay),
              value: resultsAppeared
            )

          // Manually picked recipe override
          if let manuallyPickedRecipe {
            manualRecipeCard(manuallyPickedRecipe)
              .opacity(resultsAppeared ? 1 : 0)
              .offset(y: resultsAppeared ? 0 : 12)
              .animation(
                reduceMotion
                  ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay * 2),
                value: resultsAppeared
              )
          } else if !analysis.candidateRecipes.isEmpty {
            // Recipe candidates
            recipeCandidatesSection(analysis)
              .opacity(resultsAppeared ? 1 : 0)
              .offset(y: resultsAppeared ? 0 : 12)
              .animation(
                reduceMotion
                  ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay * 2),
                value: resultsAppeared
              )
          }

          // Macros card
          macrosSection
            .opacity(resultsAppeared ? 1 : 0)
            .offset(y: resultsAppeared ? 0 : 12)
            .animation(
              reduceMotion
                ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay * 3),
              value: resultsAppeared
            )

          // Fallback / manual entry
          if analysis.candidateRecipes.isEmpty && manuallyPickedRecipe == nil {
            estimateFallbackSection(analysis)
              .opacity(resultsAppeared ? 1 : 0)
              .offset(y: resultsAppeared ? 0 : 12)
              .animation(
                reduceMotion
                  ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay * 3),
                value: resultsAppeared
              )
          }

          // Select recipe manually button
          selectRecipeManuallyButton
            .opacity(resultsAppeared ? 1 : 0)
            .offset(y: resultsAppeared ? 0 : 8)
            .animation(
              reduceMotion
                ? nil : AppMotion.cardSpring.delay(AppMotion.staggerDelay * 4),
              value: resultsAppeared
            )

          // Error inline
          if let errorMessage {
            Text(errorMessage)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.warning)
          }

          Spacer(minLength: AppTheme.Space.bottomClearance)
        }
      }
      .onAppear {
        if !resultsAppeared {
          if reduceMotion {
            resultsAppeared = true
          } else {
            withAnimation(AppMotion.cardSpring.delay(0.05)) {
              resultsAppeared = true
            }
          }
        }
      }
    }
  }

  // MARK: - Detection Summary

  private func detectionSummarySection(_ analysis: ReverseScanAnalysis) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Detected Ingredients")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          Text("\(Int((analysis.overallDetectionConfidence * 100).rounded()))%")
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(
              analysis.overallDetectionConfidence >= 0.7
                ? AppTheme.sage : AppTheme.accent
            )
            .contentTransition(.numericText())
        }

        if analysis.usedCloudAgent {
          HStack(spacing: AppTheme.Space.xxs) {
            Image(systemName: "cloud.fill")
              .font(.system(size: 10))
            Text("Cloud-enhanced matching")
              .font(AppTheme.Typography.labelSmall)
          }
          .foregroundStyle(AppTheme.sage)
        }

        Text("Confidence mode: \(analysis.confidenceAssessment.mode.statusText)")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)

        if analysis.detections.isEmpty {
          Text("No clear ingredients detected.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        } else {
          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(Array(analysis.detections.prefix(12))) { detection in
              HStack(spacing: AppTheme.Space.xxs) {
                Text(detection.label)
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textPrimary)
                Text("\(Int((detection.confidence * 100).rounded()))%")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.chipVertical)
              .background(AppTheme.surfaceMuted, in: Capsule())
            }
          }
        }
      }
    }
  }

  // MARK: - Recipe Candidates

  private func recipeCandidatesSection(_ analysis: ReverseScanAnalysis) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Recipe Matches")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)

          Spacer()

          confidencePill(analysis)
        }

        ForEach(Array(analysis.candidateRecipes.prefix(4).enumerated()), id: \.element.id) {
          index, candidate in
          Button {
            withAnimation(reduceMotion ? nil : AppMotion.gentle) {
              selectedCandidateID = candidate.id
              manuallyPickedRecipe = nil
              manuallyPickedMacros = nil
            }
          } label: {
            HStack(spacing: AppTheme.Space.sm) {
              VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
                Text(candidate.recipe.recipe.title)
                  .font(AppTheme.Typography.bodyMedium)
                  .foregroundStyle(AppTheme.textPrimary)
                  .lineLimit(2)

                HStack(spacing: AppTheme.Space.xs) {
                  Text(
                    "\(Int((candidate.confidenceScore * 100).rounded()))% match"
                  )
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(
                    candidate.confidenceScore >= 0.7
                      ? AppTheme.sage : AppTheme.textSecondary
                  )
                  .contentTransition(.numericText())

                  if candidate.recipe.missingRequiredCount > 0 {
                    Text(
                      "· \(candidate.recipe.missingRequiredCount) missing"
                    )
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.dustyRose)
                  }
                }

                if let explanation = candidate.explanation, !explanation.isEmpty {
                  Text(explanation)
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                }
              }

              Spacer()

              let isSelected =
                selectedCandidateID == candidate.id
                || (selectedCandidateID == nil
                  && analysis.candidateRecipes.first?.id == candidate.id)
              Image(
                systemName: isSelected
                  ? "checkmark.circle.fill" : "circle"
              )
              .font(.system(size: 20, weight: .medium))
              .foregroundStyle(
                isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.5)
              )
              .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isSelected)
              .symbolEffect(
                .bounce,
                options: reduceMotion ? .nonRepeating : .default,
                value: isSelected
              )
            }
            .padding(.vertical, AppTheme.Space.xs)
          }
          .buttonStyle(.plain)

          if index < min(analysis.candidateRecipes.count, 4) - 1 {
            Divider()
          }
        }
      }
    }
  }

  // MARK: - Manual Recipe Card

  private func manualRecipeCard(_ recipe: Recipe) -> some View {
    FLCard(tone: .success) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Selected Recipe")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          FLStatusPill(text: "Manual", kind: .neutral)
        }

        Text(recipe.title)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)

        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "clock")
            .font(.system(size: 11))
          Text("\(recipe.timeMinutes) min")
            .font(AppTheme.Typography.labelSmall)
          Text("·")
          Text("\(recipe.servings) servings")
            .font(AppTheme.Typography.labelSmall)
        }
        .foregroundStyle(AppTheme.textSecondary)

        Button {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            manuallyPickedRecipe = nil
            manuallyPickedMacros = nil
          }
        } label: {
          Label("Clear Selection", systemImage: "xmark.circle")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.dustyRose)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: - Macros Section

  @ViewBuilder
  private var macrosSection: some View {
    if let manuallyPickedRecipe, let macros = manuallyPickedMacros {
      macroConfirmCard(
        title: manuallyPickedRecipe.title,
        macros: macros,
        isHighConfidence: true
      )
    } else if let candidate = selectedCandidate {
      macroConfirmCard(
        title: candidate.recipe.recipe.title,
        macros: candidate.recipe.macros,
        isHighConfidence: analysis?.confidenceAssessment.mode == .exact
      )
    }
  }

  private func macroConfirmCard(
    title: String,
    macros: RecipeMacros,
    isHighConfidence: Bool
  ) -> some View {
    FLCard(tone: isHighConfidence ? .success : .warning) {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        Text("Macro Calculation")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)

        HStack(spacing: AppTheme.Space.md) {
          macroMetric(
            "Calories",
            value: macros.caloriesPerServing * Double(servings),
            unit: "kcal"
          )
          macroMetric(
            "Protein",
            value: macros.proteinPerServing * Double(servings),
            unit: "g"
          )
          macroMetric(
            "Carbs",
            value: macros.carbsPerServing * Double(servings),
            unit: "g"
          )
          macroMetric(
            "Fat",
            value: macros.fatPerServing * Double(servings),
            unit: "g"
          )
        }

        Stepper(value: $servings, in: 1...8) {
          Text("Servings consumed: \(servings)")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        FLPrimaryButton(
          isLoggingMeal ? "Logging..." : "Confirm & Log Meal",
          systemImage: "checkmark",
          isEnabled: !isLoggingMeal
        ) {
          Task { await logMeal() }
        }
      }
    }
  }

  // MARK: - Estimate Fallback

  private func estimateFallbackSection(_ analysis: ReverseScanAnalysis) -> some View {
    FLCard(tone: .warning) {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        Text("Estimate Fallback")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)

        Text(
          "No strong recipe match found. Select a recipe manually for accurate macros, or use the template estimate below."
        )
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

        if let template = analysis.fallbackTemplate {
          Text("Template: \(template.name)")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
        }

        Picker("Portion", selection: $portionSize) {
          ForEach(DishPortionSize.allCases, id: \.self) { size in
            Text(size.displayName).tag(size)
          }
        }
        .pickerStyle(.segmented)

        if let fallbackEstimate {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            estimateRow("Calories", range: fallbackEstimate.calories, unit: "kcal")
            estimateRow("Protein", range: fallbackEstimate.protein, unit: "g")
            estimateRow("Carbs", range: fallbackEstimate.carbs, unit: "g")
            estimateRow("Fat", range: fallbackEstimate.fat, unit: "g")
          }
        }
      }
    }
  }

  // MARK: - Select Recipe Manually

  private var selectRecipeManuallyButton: some View {
    Button {
      showRecipePicker = true
    } label: {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "text.book.closed")
          .font(.system(size: 15, weight: .medium))
        Text("Select a recipe manually")
          .font(AppTheme.Typography.label)
      }
      .foregroundStyle(AppTheme.accent)
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.buttonVertical)
      .background(
        AppTheme.accent.opacity(0.06),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.accent.opacity(0.20), lineWidth: 1)
      )
    }
    .buttonStyle(FLPressableButtonStyle())
  }

  // MARK: - Error

  private func errorResultView(_ message: String) -> some View {
    VStack(spacing: AppTheme.Space.lg) {
      if let capturedImage {
        Image(uiImage: capturedImage)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 190)
          .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
      }

      VStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.accent)

        Text("Couldn't analyze meal")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text(message)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLSecondaryButton("Retry", systemImage: "arrow.clockwise") {
          retryScan()
        }

        Button {
          showRecipePicker = true
        } label: {
          Label("Select a recipe manually", systemImage: "text.book.closed")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, AppTheme.Space.xs)
      }
    }
  }

  // MARK: - Confidence Pill

  private func confidencePill(_ analysis: ReverseScanAnalysis) -> some View {
    Group {
      switch analysis.confidenceAssessment.mode {
      case .exact:
        FLStatusPill(text: "High confidence", kind: .positive)
      case .reviewRequired:
        FLStatusPill(text: "Needs confirmation", kind: .warning)
      case .estimateOnly:
        FLStatusPill(text: "Estimate mode", kind: .neutral)
      }
    }
  }

  // MARK: - Helper Views

  private func macroMetric(_ title: String, value: Double, unit: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      Text(title)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      Text("\(Int(value.rounded()))\(unit)")
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func estimateRow(
    _ title: String, range: NutrientRange, unit: String
  ) -> some View {
    HStack {
      Text(title)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
      Text("\(Int(range.min.rounded()))-\(Int(range.max.rounded())) \(unit)")
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
    }
  }

  // MARK: - Actions

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

        capturedImage = ScanImagePreprocessor.prepare(image)
      } catch {
        errorMessage = "Could not load the selected photo. Try another image."
      }
    }
  }

  private func retryScan() {
    logger.debug("Reverse scan retry requested by user.")
    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
      capturedImage = nil
      analysis = nil
      errorMessage = nil
      selectedCandidateID = nil
      manuallyPickedRecipe = nil
      manuallyPickedMacros = nil
      resultsAppeared = false
      servings = 1
    }
  }

  private func analyze() async {
    guard let capturedImage else { return }
    logger.info("Reverse scan UI analyze started.")
    errorMessage = nil
    resultsAppeared = false

    let startedAt = Date()
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      isAnalyzing = true
    }

    defer {
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        isAnalyzing = false
      }
    }

    do {
      let result = try await deps.reverseScanService.analyzeMealPhoto(capturedImage)

      // Enforce minimum analyze duration for perceived thoroughness
      let elapsed = Date().timeIntervalSince(startedAt)
      let minDuration = reduceMotion ? 0.35 : 1.3
      if elapsed < minDuration {
        let remaining = minDuration - elapsed
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
      }

      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        analysis = result
        selectedCandidateID = result.candidateRecipes.first?.id
      }
      logger.info(
        "Reverse scan UI analyze completed. candidates=\(result.candidateRecipes.count, privacy: .public), mode=\(result.confidenceAssessment.mode.rawValue, privacy: .public), deterministic=\(result.deterministicRecipeReady, privacy: .public)"
      )
    } catch {
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        analysis = nil
        errorMessage = error.localizedDescription
      }
      logger.error(
        "Reverse scan UI analyze failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func logMeal() async {
    guard !isLoggingMeal else { return }
    logger.info("Reverse scan meal log requested.")

    // Determine recipe + macros source
    let recipeToLog: Recipe
    if let manuallyPickedRecipe {
      recipeToLog = manuallyPickedRecipe
    } else if let candidate = selectedCandidate {
      recipeToLog = candidate.recipe.recipe
    } else {
      errorMessage = "Select a recipe before logging."
      logger.notice("Meal log blocked: no recipe selected.")
      return
    }

    isLoggingMeal = true
    defer { isLoggingMeal = false }

    do {
      let mealOutcome = try deps.mealLogService.logMeal(
        recipe: recipeToLog,
        rating: nil,
        capturedImage: capturedImage,
        servingsConsumed: servings,
        sourceRefPrefix: "reverse_scan"
      )

      await deps.mealLogSyncCoordinator.syncLoggedMeal(
        historyId: mealOutcome.historyId,
        recipeId: mealOutcome.recipeId,
        mealTitle: recipeToLog.title,
        servingsConsumed: servings
      )

      if let analysis {
        let reward: Double
        if manuallyPickedRecipe != nil {
          reward = 0.45
        } else if let selectedCandidate,
          let topID = analysis.candidateRecipes.first?.id
        {
          reward = selectedCandidate.id == topID ? 0.96 : 0.78
        } else {
          reward = 0.72
        }

        deps.confidenceLearningService.recordOutcome(
          assessment: analysis.confidenceAssessment,
          outcomeReward: reward,
          contextKey: "reverse_scan:\(mealOutcome.recipeId)",
          note: manuallyPickedRecipe != nil ? "manual_recipe_override" : "candidate_confirmed"
        )
        logger.info(
          "Recorded confidence-learning outcome. reward=\(reward, privacy: .public), recipeId=\(mealOutcome.recipeId, privacy: .public)"
        )
      }

      showLogSuccess = true
      logger.info("Meal log succeeded.")
    } catch {
      errorMessage = error.localizedDescription
      logger.error("Meal log failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
