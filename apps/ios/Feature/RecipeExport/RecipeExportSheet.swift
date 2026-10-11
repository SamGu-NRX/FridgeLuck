import FLFeatureLogic
import SwiftUI

/// Sheet for exporting the recipe preview's ingredient amounts as plain text.
///
/// `RecipeExportSession` is the single source of truth: once prepared, the
/// document is frozen and is never re-rendered from live preview state. Live
/// drift is surfaced as a "Reprepare" action instead of silently changing it.
struct RecipeExportSheet: View {
  /// Fresh intake builder provided by the drawer. Re-reads the repository on
  /// every call and throws `RecipeExportError` for missing/failed reads.
  let buildFreshIntake: () throws -> RecipeExportIntake

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  @State private var session = RecipeExportSession()
  @State private var probeInFlight = true
  @State private var probeError: RecipeExportError?
  @State private var exportServings = 1
  @State private var weightPresentation = RecipeExportQuantityPresentation.metricGrams
  @State private var isStaleFromLiveChanges = false
  @State private var interactionNotice: String?
  @State private var showShareSheet = false
  @State private var showFileExporter = false
  @State private var prepareTask: Task<Void, Never>?

  private static let driftPollInterval: UInt64 = 1_500_000_000

  var body: some View {
    NavigationStack {
      content
        .padding(.horizontal, AppTheme.Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Export amounts")
        .navigationBarTitleDisplayMode(.inline)
        .background(AppTheme.bg)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
          }
        }
    }
    .task { await runIntakeProbe() }
    .task { await pollForDriftWhileVisible() }
    .onDisappear { prepareTask?.cancel() }
  }

  @ViewBuilder
  private var content: some View {
    switch session.status {
    case .idle:
      if probeInFlight {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let refusal = probeError {
        refusalView(refusal)
      } else {
        setupView
      }
    case .preparing:
      preparingView
    case .prepared:
      if let prepared = session.prepared {
        preparedView(prepared)
      } else {
        preparingView
      }
    case .prepareFailed(let error):
      failureView(error)
    }
  }

  // MARK: - Setup State

  private var setupView: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Text("Servings to export")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
        Stepper(value: $exportServings, in: 1...999) {
          Text("\(exportServings) servings")
            .font(AppTheme.Typography.settingsBody)
        }
        .accessibilityLabel("Servings to export")
        .accessibilityValue("\(exportServings)")
      }

      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Text("Weight presentation")
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.textSecondary)
        Picker("Weight presentation", selection: $weightPresentation) {
          Text("Metric (grams)").tag(RecipeExportQuantityPresentation.metricGrams)
          Text("Imperial (ounces)").tag(RecipeExportQuantityPresentation.imperialOunces)
        }
        .pickerStyle(.segmented)
      }

      Button("Prepare document") {
        prepareDocument()
      }
      .buttonStyle(.borderedProminent)
      .tint(AppTheme.accent)
      .frame(maxWidth: .infinity)
    }
    .padding(.top, AppTheme.Space.lg)
  }

  // MARK: - Prepared State

  private func preparedView(_ prepared: RecipeExportPrepared) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      if isStaleFromLiveChanges {
        staleBanner
      }

      ScrollView {
        // The frozen prepared document, rendered from session state only.
        Text(prepared.renderedText())
          .font(AppTheme.Export.document)
          .lineSpacing(AppTheme.Export.documentLineSpacing)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(AppTheme.Space.md)
      }
      .background(
        AppTheme.surface.opacity(0.6),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
      )

      HStack(spacing: AppTheme.Space.sm) {
        Button("Share") {
          showShareSheet = true
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.accent)

        Button("Save as File") {
          showFileExporter = true
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.accent)
      }

      if let notice = interactionNotice {
        Text(notice)
          .font(AppTheme.Typography.settingsCaption)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(.top, AppTheme.Space.md)
    .fileExporter(
      isPresented: $showFileExporter,
      document: RecipeExportTextDocument(text: prepared.renderedText()),
      contentType: .plainText,
      defaultFilename: RecipeExportFilename.defaultName(
        recipeName: prepared.recipeName,
        exportedServings: prepared.exportedServings
      ),
      onCompletion: handleFileExportResult
    )
    .sheet(isPresented: $showShareSheet) {
      RecipeExportShareSheet(
        text: prepared.renderedText(),
        onClosed: handleShareClosed
      )
    }
  }

  private var staleBanner: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(AppTheme.warning)
        .accessibilityHidden(true)
      Text("Preview changed")
        .font(AppTheme.Typography.settingsCaptionMedium)
      Spacer()
      Button("Reprepare") {
        prepareDocument()
      }
      .font(AppTheme.Typography.settingsCaptionMedium)
      .buttonStyle(.borderedProminent)
      .tint(AppTheme.accent)
    }
    .padding(AppTheme.Space.sm)
    .background(AppTheme.Export.bannerFill, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
  }

  // MARK: - Preparing / Failure / Refusal States

  private var preparingView: some View {
    VStack(spacing: AppTheme.Space.md) {
      ProgressView("Preparing document…")
        .font(AppTheme.Typography.settingsBody)
      Button("Cancel") {
        prepareTask?.cancel()
        session.cancelPreparation()
      }
      .buttonStyle(.bordered)
      .tint(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, AppTheme.Space.xl)
  }

  private func failureView(_ error: RecipeExportError) -> some View {
    refusalContent(
      message: message(for: error),
      retryTitle: "Retry"
    ) {
      prepareDocument()
    }
  }

  private func refusalView(_ error: RecipeExportError) -> some View {
    refusalContent(
      message: message(for: error),
      retryTitle: "Retry"
    ) {
      Task { await runIntakeProbe() }
    }
  }

  private func refusalContent(
    message: String,
    retryTitle: String,
    retry: @escaping () -> Void
  ) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      Image(systemName: "doc.badge.exclamationmark")
        .font(.largeTitle)
        .foregroundStyle(AppTheme.warning)
        .accessibilityHidden(true)
      Text("Can't export this recipe")
        .font(AppTheme.Typography.settingsHeadline)
      Text(message)
        .font(AppTheme.Typography.settingsDetail)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
      Button(retryTitle) {
        retry()
      }
      .buttonStyle(.bordered)
      .tint(AppTheme.accent)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, AppTheme.Space.xl)
  }

  // MARK: - Logic

  /// Distinct plain wording for every RecipeExportError kind.
  private func message(for error: RecipeExportError) -> String {
    switch error {
    case .recipeReadFailed:
      return "The recipe's ingredients could not be read."
    case .recipeMissing:
      return "This recipe is no longer available."
    case .inconsistentRecipeRead(let detail):
      return "The recipe's data is inconsistent (\(detail))."
    case .invalidOriginalServings(let value):
      let shown = value.map(String.init) ?? "missing"
      return "The recipe's original serving count is invalid (\(shown))."
    case .invalidExportServings(let value):
      return "The export serving count must be a positive number (got \(value))."
    }
  }

  /// Reads the intake once on open so a refusal state can replace the setup
  /// controls when the preview cannot back an export.
  @MainActor
  private func runIntakeProbe() async {
    probeInFlight = true
    do {
      let intake = try buildFreshIntake()
      probeError = nil
      exportServings = intake.originalServings ?? 1
    } catch {
      probeError = (error as? RecipeExportError) ?? .recipeReadFailed
    }
    probeInFlight = false
  }

  /// Runs the fresh read on the main actor and the preparer off it; the
  /// session's generation token discards stale completions.
  @MainActor
  private func prepareDocument() {
    let token = session.beginPreparation()
    let intake: RecipeExportIntake
    do {
      intake = try buildFreshIntake()
    } catch {
      session.fail((error as? RecipeExportError) ?? .recipeReadFailed, generation: token)
      return
    }
    let chosenServings = Double(exportServings)
    let chosenPresentation = weightPresentation
    prepareTask = Task {
      do {
        let prepared = try await Task.detached(priority: .userInitiated) {
          try RecipeExportPreparer.prepare(
            intake: intake,
            exportedServings: chosenServings,
            presentation: chosenPresentation
          )
        }.value
        acceptPreparation(prepared, token: token)
      } catch {
        refusePreparation((error as? RecipeExportError) ?? .recipeReadFailed, token: token)
      }
    }
  }

  @MainActor
  private func acceptPreparation(_ prepared: RecipeExportPrepared, token: Int) {
    session.complete(prepared, generation: token)
    // Only reset the stale banner when the session accepted this document;
    // a stale-generation completion is discarded by the session itself.
    if session.prepared == prepared {
      interactionNotice = nil
      withAnimation(reduceMotion ? nil : AppMotion.Export.stateChange) {
        isStaleFromLiveChanges = false
      }
    }
  }

  @MainActor
  private func refusePreparation(_ error: RecipeExportError, token: Int) {
    session.fail(error, generation: token)
  }

  /// Polls for live-state drift while a prepared document is on screen. The
  /// fresh read is cheap (local SQLite) and the sheet is modal, so a 1.5s
  /// interval catches out-of-band repository changes without an observable
  /// signal from the drawer.
  private func pollForDriftWhileVisible() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: Self.driftPollInterval)
      if Task.isCancelled { break }
      await refreshDriftState()
    }
  }

  @MainActor
  private func refreshDriftState() {
    guard case .prepared = session.status, let prepared = session.prepared else {
      if isStaleFromLiveChanges {
        isStaleFromLiveChanges = false
      }
      return
    }
    let liveIntake: RecipeExportIntake?
    do {
      liveIntake = try buildFreshIntake()
    } catch {
      // A failed fresh read means the live state no longer backs the document.
      liveIntake = nil
    }
    let stale = liveIntake.map {
      RecipeExportDrift.isStale(liveIntake: $0, prepared: prepared)
    } ?? true
    withAnimation(reduceMotion ? nil : AppMotion.Export.stateChange) {
      isStaleFromLiveChanges = stale
    }
  }

  // MARK: - Delivery Interactions

  /// Neutral by design: a closed share sheet never confirms delivery.
  private func handleShareClosed(userCompleted: Bool) {
    session.noteInteraction(userCompleted ? .shareSheetClosed : .shareCancelled)
    interactionNotice = "Share sheet closed — delivery not confirmed"
  }

  /// saveCompleted is reported only from the actual fileExporter result.
  private func handleFileExportResult(_ result: Result<URL, Error>) {
    switch result {
    case .success:
      session.noteInteraction(.saveCompleted)
      interactionNotice = "File saved."
    case .failure(let error):
      if (error as NSError).code == NSUserCancelledError {
        session.noteInteraction(.saveCancelled)
        interactionNotice = "Save cancelled — no file written."
      } else {
        session.noteInteraction(.saveFailed(error.localizedDescription))
        interactionNotice = "Save failed: \(error.localizedDescription)"
      }
    }
  }
}
