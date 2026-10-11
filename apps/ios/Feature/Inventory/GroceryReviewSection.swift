import FLFeatureLogic
import SwiftUI

struct GroceryReviewSection: View {
  @Binding var items: [GroceryPendingItem]
  let isCommitting: Bool
  let onCommit: () -> Void
  var onAddMore: (() -> Void)? = nil
  /// Opens the ingredient search to correct or choose an item's food.
  var onPickIdentity: ((UUID) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  private var confirmedItems: [GroceryPendingItem] {
    items.filter(\.isConfirmed)
  }

  private var confirmedUnresolvedCount: Int {
    confirmedItems.filter { !$0.isResolvedForCommit }.count
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        HStack {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("Review Items")
              .font(.system(.title2, design: .serif, weight: .bold))
              .foregroundStyle(AppTheme.textPrimary)

            Text(subtitle)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
              .contentTransition(.numericText())
          }
          Spacer()
        }
        .padding(.horizontal, AppTheme.Space.page)

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            groceryItemCard(item: item, index: index)
              .opacity(appeared ? 1 : 0)
              .offset(y: appeared ? 0 : 12)
              .animation(
                reduceMotion
                  ? nil
                  : AppMotion.cardSpring.delay(Double(min(index, 12)) * 0.025),
                value: appeared
              )
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        if let onAddMore {
          Button(action: onAddMore) {
            HStack(spacing: AppTheme.Space.sm) {
              Image(systemName: "plus.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTheme.accent)

              Text("Add more items")
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.accent)

              Spacer()
            }
            .padding(AppTheme.Space.md)
            .background(
              RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .stroke(
                  AppTheme.accent.opacity(0.30), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
          }
          .buttonStyle(FLPressableButtonStyle())
          .padding(.horizontal, AppTheme.Space.page)
        }

        FLPrimaryButton(
          commitTitle,
          systemImage: "plus.circle.fill",
          isEnabled: canCommit && !isCommitting
        ) {
          onCommit()
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.sm)

        Spacer(minLength: AppTheme.Space.bottomClearance)
      }
      .padding(.top, AppTheme.Space.md)
    }
    .onAppear {
      if !appeared {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.cardSpring.delay(0.05)) {
            appeared = true
          }
        }
      }
    }
  }

  private var subtitle: String {
    if confirmedUnresolvedCount > 0 {
      return
        "Adding \(confirmedItems.count) item\(confirmedItems.count == 1 ? "" : "s") — \(confirmedUnresolvedCount) need\(confirmedUnresolvedCount == 1 ? "s" : "") an amount or food"
    }
    return "Adding \(confirmedItems.count) item\(confirmedItems.count == 1 ? "" : "s") to your kitchen"
  }

  private var commitTitle: String {
    if confirmedUnresolvedCount > 0 {
      return "Set \(confirmedUnresolvedCount) amount\(confirmedUnresolvedCount == 1 ? "" : "s") to continue"
    }
    return
      "Confirm & Add \(confirmedItems.count) Item\(confirmedItems.count == 1 ? "" : "s")"
  }

  private var canCommit: Bool {
    !confirmedItems.isEmpty && confirmedUnresolvedCount == 0
  }

  // MARK: - Item Card

  private func groceryItemCard(item: GroceryPendingItem, index: Int) -> some View {
    FLCard(tone: item.isConfirmed ? (item.isResolvedForCommit ? .success : .warning) : .normal) {
      VStack(spacing: AppTheme.Space.sm) {
        HStack(spacing: AppTheme.Space.sm) {
          Button {
            withAnimation(reduceMotion ? nil : AppMotion.gentle) {
              items[index].isConfirmed.toggle()
            }
          } label: {
            Image(systemName: item.isConfirmed ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(item.isConfirmed ? AppTheme.sage : AppTheme.oat.opacity(0.5))
              .animation(reduceMotion ? nil : AppMotion.colorTransition, value: item.isConfirmed)
          }
          .buttonStyle(.plain)

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(item.ingredientName)
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: AppTheme.Space.xs) {
              identityPill(item)
              if let evidence = item.evidenceSummary {
                Text(evidence)
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
                  .lineLimit(1)
              }
            }
          }

          Spacer()

          Button {
            withAnimation(reduceMotion ? nil : AppMotion.gentle) {
              let removalIndex = items.index(items.startIndex, offsetBy: index)
              items.remove(at: removalIndex)
            }
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(AppTheme.oat.opacity(0.5))
          }
          .buttonStyle(.plain)
        }

        amountAndLocationRow(item: item, index: index)
      }
    }
  }

  /// Identity state: which food this is, and how to correct it. Unresolved items offer the
  /// alternatives recognition considered plus a search.
  @ViewBuilder
  private func identityPill(_ item: GroceryPendingItem) -> some View {
    if item.source == .manual {
      FLStatusPill(text: "Manual", kind: .neutral)
    } else {
      confidencePill(item.confidenceScore)
    }

    if item.ingredientId == nil {
      Button {
        onPickIdentity?(item.id)
      } label: {
        HStack(spacing: 2) {
          Image(systemName: "questionmark.circle")
            .font(.system(size: 11, weight: .medium))
          Text("Which food?")
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.accent)
      }
      .buttonStyle(.plain)
    } else if !item.alternatives.isEmpty || onPickIdentity != nil {
      Menu {
        ForEach(item.alternatives) { alternative in
          Button(alternative.name) {
            replaceIdentity(of: item, with: alternative)
          }
        }
        if let onPickIdentity {
          Button("Search…") {
            onPickIdentity(item.id)
          }
        }
      } label: {
        HStack(spacing: 2) {
          Image(systemName: "arrow.2.squarepath")
            .font(.system(size: 11, weight: .medium))
          Text("Wrong food?")
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func replaceIdentity(of item: GroceryPendingItem, with alternative: GroceryAlternative) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    let estimatedGrams = alternative.id == item.ingredientId
      ? item.quantityGrams
      : InventoryIntakeService.estimateGramsIfKnown(
        forName: IngredientLexicon.displayName(for: alternative.id))
    items[index].replaceIdentity(
      ingredientId: alternative.id,
      name: IngredientLexicon.displayName(for: alternative.id),
      estimatedGrams: estimatedGrams
    )
  }

  /// Amount (with honest provenance) and storage location.
  @ViewBuilder
  private func amountAndLocationRow(item: GroceryPendingItem, index: Int) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      if let grams = item.quantityGrams {
        amountStepper(item: item, index: index, grams: grams)
      } else {
        amountEntryField(item: item, index: index)
      }

      Spacer()

      Picker("Location", selection: Binding(
        get: { items[safe: index]?.storageLocation ?? .unknown },
        set: { items[safe: index]?.storageLocation = $0 }
      )) {
        Text("Fridge").tag(InventoryStorageLocation.fridge)
        Text("Pantry").tag(InventoryStorageLocation.pantry)
        Text("Freezer").tag(InventoryStorageLocation.freezer)
      }
      .pickerStyle(.menu)
      .font(AppTheme.Typography.labelSmall)
      .tint(AppTheme.accent)
    }
  }

  private func amountStepper(item: GroceryPendingItem, index: Int, grams: Double) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Text("Qty:")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)

      Text("\(Int(grams.rounded()))g")
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
        .contentTransition(.numericText())
        .frame(minWidth: 36)

      provenanceTag(item)

      Stepper(
        "",
        value: Binding(
          get: { items[safe: index]?.quantityGrams ?? grams },
          set: { newValue in
            guard index < items.count else { return }
            // Stepping replaces the stored amount with the user's own value.
            items[index].setAmount(max(5, newValue), provenance: .entered)
          }
        ),
        in: 5...5000,
        step: 25
      )
      .labelsHidden()
      .fixedSize()
    }
  }

  /// Unknown amounts ask for a value instead of showing a guess. Accepts plain grams
  /// ("500") or an explicit weight ("12 oz", "0.5 kg") — the unit marks it as measured.
  private func amountEntryField(item: GroceryPendingItem, index: Int) -> some View {
    AmountEntryField { text in
      guard index < items.count,
        let parsed = GroceryIntakeNormalizer.parseUserAmount(text)
      else { return false }
      items[index].setAmount(parsed.grams, provenance: QuantityProvenance(rawValue: parsed.provenance.rawValue)!)
      return true
    }
  }

  /// Reads "est." for heuristic amounts and nothing for the user's own values — the Kitchen
  /// carries the same distinction into how the amount is displayed later.
  @ViewBuilder
  private func provenanceTag(_ item: GroceryPendingItem) -> some View {
    if item.quantityProvenance == .estimate {
      Text("est.")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
    } else if item.quantityProvenance == .measured {
      Text("measured")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.sage)
    }
  }

  private func confidencePill(_ confidence: Double) -> some View {
    let percentage = Int((confidence * 100).rounded())
    let kind: FLStatusPill.Kind =
      confidence >= 0.80 ? .positive : confidence >= 0.50 ? .warning : .neutral
    return FLStatusPill(text: "\(percentage)%", kind: kind)
  }
}

/// Inline "Set amount" field for unknown amounts. Submitting a parsable value resolves the
/// item; anything else keeps the field open.
private struct AmountEntryField: View {
  let onResolve: (String) -> Bool

  @State private var text = ""
  @State private var showField = false
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Text("Qty:")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)

      if showField {
        TextField("500g or 12 oz", text: $text)
          .textFieldStyle(.roundedBorder)
          .font(AppTheme.Typography.dataSmall)
          .keyboardType(.numbersAndPunctuation)
          .frame(maxWidth: 130)
          .focused($isFocused)
          .onSubmit(resolve)
          .submitLabel(.done)

        Button("Set") { resolve() }
          .font(AppTheme.Typography.labelSmall)
          .buttonStyle(.borderless)
      } else {
        Button {
          showField = true
          isFocused = true
        } label: {
          HStack(spacing: 2) {
            Image(systemName: "scale.3d")
              .font(.system(size: 11, weight: .medium))
            Text("Set amount")
          }
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func resolve() {
    if onResolve(text) {
      showField = false
      text = ""
    }
  }
}

// MARK: - Safe Array Subscript

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
