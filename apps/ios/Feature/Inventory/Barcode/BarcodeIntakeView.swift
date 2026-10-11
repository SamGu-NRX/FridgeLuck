import FLBarcode
import SwiftUI

/// Barcode grocery intake: manual GTIN entry plus an on-device scanner (VisionKit) with
/// graceful fallback to manual entry. Drafts are built from explicit evidence only and
/// commit through PR42's session path with a stable source ref, so retries and double
/// taps never duplicate food.
struct BarcodeIntakeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  @State private var coordinator: BarcodeIntakeCoordinator?
  @State private var drafts: [BarcodeDraftItem] = []
  @State private var manualGTIN = ""
  @State private var manualEntryMessage: String?
  @State private var showScanner = false
  @State private var identityPickTarget: IdentityPickTarget?
  @State private var amountInputs: [UUID: String] = [:]
  @State private var isCommitting = false
  @State private var commitFailure: String?
  @State private var showSuccess = false
  @State private var committedLots = 0

  private let scannerAvailable = BarcodeScannerView.isScannerAvailable()

  struct IdentityPickTarget: Identifiable {
    let draftID: UUID
    var id: UUID { draftID }
  }

  private var resolvedCount: Int {
    drafts.filter(\.isResolvedForCommit).count
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: AppTheme.Space.lg) {
          entryCard
          draftList
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.vertical, AppTheme.Space.lg)
      }
      .navigationTitle("Scan barcodes")
      .navigationBarTitleDisplayMode(.inline)
      .flPageBackground()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { cancelSession() }
        }
      }
      .safeAreaInset(edge: .bottom) { commitBar }
    }
    .onAppear {
      if coordinator == nil {
        coordinator = BarcodeIntakeWiring.makeCoordinator(deps: deps)
      }
    }
    .fullScreenCover(isPresented: $showScanner) { scannerCover }
    .sheet(item: $identityPickTarget) { target in
      IngredientPickerView(
        title: "Which food is this?",
        onPickSingle: { ingredient in
          pickIdentity(ingredient, for: target.draftID)
          identityPickTarget = nil
        }
      )
    }
    .overlay {
      if showSuccess { successOverlay }
    }
    .alert(
      "Couldn't add these",
      isPresented: Binding(
        get: { commitFailure != nil },
        set: { if !$0 { commitFailure = nil } }
      )
    ) {
      Button("Try Again") { commitAll() }
      Button("OK", role: .cancel) {}
    } message: {
      Text(commitFailure ?? "")
    }
  }

  // MARK: - Entry

  private var entryCard: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      if scannerAvailable {
        Button {
          showScanner = true
        } label: {
          Label("Scan a barcode", systemImage: "barcode.viewfinder")
            .font(AppTheme.Typography.bodyMedium)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FLPressableButtonStyle())
        .tint(AppTheme.accent)
      } else {
        Label(
          "The scanner isn't available here — enter the number below the barcode.",
          systemImage: "barcode")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      HStack(spacing: AppTheme.Space.sm) {
        TextField("Barcode number", text: $manualGTIN)
          .keyboardType(.numberPad)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.done)
          .onSubmit(addManualGTIN)

        Button(action: addManualGTIN) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 24))
        }
        .tint(AppTheme.accent)
        .disabled(manualGTIN.trimmingCharacters(in: .whitespaces).isEmpty)
      }

      if let manualEntryMessage {
        Text(manualEntryMessage)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
  }

  // MARK: - Drafts

  @ViewBuilder
  private var draftList: some View {
    if drafts.isEmpty {
      VStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "checkmark.shield")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(AppTheme.oat.opacity(0.6))
        Text(
          "Scan or type a barcode to start.\nPackage weight fills the amount when it's printed on the product."
        )
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, AppTheme.Space.xl)
    } else {
      VStack(spacing: AppTheme.Space.md) {
        ForEach(drafts) { draft in
          draftRow(draft)
        }
      }
    }
  }

  private func draftRow(_ draft: BarcodeDraftItem) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(draft.title)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(2)
          if let brands = draft.brands, !brands.isEmpty {
            Text(brands)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        Spacer()
        if draft.isStale {
          Text("saved data")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Button {
          removeDraft(draft)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(AppTheme.oat.opacity(0.6))
        }
        .buttonStyle(.plain)
      }

      if let evidence = draft.evidenceSummary {
        Text("Package: \(evidence)")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      identityArea(draft)
      amountArea(draft)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
  }

  /// Identity: bound names show as resolved; ambiguous shows the top suggestions (never
  /// a silent guess); unbound asks for a pick.
  @ViewBuilder
  private func identityArea(_ draft: BarcodeDraftItem) -> some View {
    switch draft.binding {
    case .bound(_, let name, _):
      Label(name, systemImage: "checkmark.circle.fill")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.sage)
    case .ambiguous(let candidates):
      suggestionsMenu(draft, candidates: candidates, prompt: "Which food is this?")
    case .unbound:
      if draft.candidates.isEmpty {
        Button {
          identityPickTarget = IdentityPickTarget(draftID: draft.id)
        } label: {
          Label("Pick a food", systemImage: "list.star")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(FLPressableButtonStyle())
      } else {
        suggestionsMenu(draft, candidates: draft.candidates, prompt: "Closest matches — pick one")
      }
    }
  }

  private func suggestionsMenu(
    _ draft: BarcodeDraftItem, candidates: [CatalogCandidate], prompt: String
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text(prompt)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      Menu {
        ForEach(Array(candidates.prefix(4))) { candidate in
          Button(candidate.name) { chooseIdentity(candidate, for: draft) }
        }
        Button("Choose another…") {
          identityPickTarget = IdentityPickTarget(draftID: draft.id)
        }
      } label: {
        Label("Choose food", systemImage: "list.star")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.accent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Amount: explicit package mass shows as measured; unknown waits for the user —
  /// prices, counts, and serving sizes never become grams on their own.
  @ViewBuilder
  private func amountArea(_ draft: BarcodeDraftItem) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      if let grams = draft.amountGrams {
        Label(
          "\(formatGrams(grams)) · \(draft.isMeasured ? "from package" : "set by you")",
          systemImage: draft.isMeasured ? "scalemass.fill" : "hand.point.up.left"
        )
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textPrimary)
      } else {
        TextField("grams", text: amountBinding(for: draft))
          .keyboardType(.decimalPad)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 120)
        Button("Set") { applyAmount(draft) }
          .buttonStyle(.bordered)
      }
      Spacer()
    }
  }

  private var commitBar: some View {
    VStack(spacing: AppTheme.Space.xs) {
      FLPrimaryButton(
        "Add \(resolvedCount) item\(resolvedCount == 1 ? "" : "s")",
        systemImage: "checkmark",
        isEnabled: resolvedCount > 0 && !isCommitting
      ) {
        commitAll()
      }
      Text("\(resolvedCount) of \(drafts.count) ready — each needs a food and an amount")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.vertical, AppTheme.Space.sm)
    .background(AppTheme.surface)
  }

  // MARK: - Scanner

  private var scannerCover: some View {
    ZStack(alignment: .bottom) {
      BarcodeScannerView { payload in
        acceptGTIN(payload)
      }
      .ignoresSafeArea()

      Button("Done") { showScanner = false }
        .buttonStyle(.borderedProminent)
        .padding(.bottom, AppTheme.Space.xl)
    }
  }

  // MARK: - Success

  private var successOverlay: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.96)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 44, weight: .semibold))
          .foregroundStyle(AppTheme.sage)
        Text("Items added!")
          .font(.system(.title2, design: .serif, weight: .bold))
          .foregroundStyle(AppTheme.textPrimary)
        Text(
          committedLots == 0
            ? "These were already in your kitchen."
            : "\(committedLots) item(s) added to your kitchen."
        )
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .task {
      try? await Task.sleep(for: .seconds(1.4))
      dismiss()
    }
  }

  // MARK: - Actions

  private func acceptGTIN(_ raw: String) {
    guard let coordinator else { return }
    Task {
      let outcome = await coordinator.accept(gtin: raw)
      mirrorDrafts()
      switch outcome {
      case .added:
        manualEntryMessage = nil
        manualGTIN = ""
        if showScanner { showScanner = false }
      case .duplicate:
        manualEntryMessage = "Already added — each product appears once."
      case .invalidGTIN:
        manualEntryMessage =
          "That number doesn't check out as a barcode — retype it or scan again."
      case .lookupFailed, .cancelled:
        manualEntryMessage = "Lookup failed — try again."
      }
    }
  }

  private func addManualGTIN() {
    let value = manualGTIN.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return }
    acceptGTIN(value)
  }

  private func chooseIdentity(_ candidate: CatalogCandidate, for draft: BarcodeDraftItem) {
    coordinator?.pickIdentity(candidate, for: draft.id)
    mirrorDrafts()
  }

  private func pickIdentity(_ ingredient: Ingredient, for draftID: UUID) {
    guard let id = ingredient.id else { return }
    coordinator?.pickIdentity(
      CatalogCandidate(id: id, name: ingredient.name, score: 1.0), for: draftID)
    mirrorDrafts()
  }

  private func applyAmount(_ draft: BarcodeDraftItem) {
    guard let text = amountInputs[draft.id],
      let grams = Double(text.trimmingCharacters(in: .whitespaces)), grams > 0
    else { return }
    coordinator?.setAmount(grams, for: draft.id)
    mirrorDrafts()
  }

  private func removeDraft(_ draft: BarcodeDraftItem) {
    coordinator?.removeDraft(id: draft.id)
    amountInputs[draft.id] = nil
    mirrorDrafts()
  }

  private func cancelSession() {
    // Cancelled capture never commits: drafts drop and the commit latch closes.
    coordinator?.cancel()
    dismiss()
  }

  private func commitAll() {
    guard let coordinator, !isCommitting else { return }
    isCommitting = true
    Task {
      let outcome = await coordinator.commitAll()
      isCommitting = false
      switch outcome {
      case .committed(let lots):
        committedLots = lots
        showSuccess = true
      case .alreadyCommitted:
        dismiss()
      case .nothingToCommit:
        commitFailure = "Nothing ready yet — give each item a food and an amount."
      case .cancelled:
        dismiss()
      case .failed:
        commitFailure =
          "Your kitchen wasn't updated — nothing was saved. Try again; adding twice is safe."
      }
    }
  }

  // MARK: - Helpers

  /// The coordinator is the source of truth; the view mirrors drafts after each call.
  private func mirrorDrafts() {
    guard let coordinator else { return }
    drafts = coordinator.drafts
    for draft in drafts where amountInputs[draft.id] == nil {
      if let grams = draft.amountGrams {
        amountInputs[draft.id] = String(Int(grams.rounded()))
      }
    }
  }

  private func amountBinding(for draft: BarcodeDraftItem) -> Binding<String> {
    Binding(
      get: { amountInputs[draft.id] ?? "" },
      set: { amountInputs[draft.id] = $0 }
    )
  }

  private func formatGrams(_ grams: Double) -> String {
    "\(Int(grams.rounded())) g"
  }
}
