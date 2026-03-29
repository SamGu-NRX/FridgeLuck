import SwiftUI

struct GroceryReviewSection: View {
  @Binding var items: [GroceryPendingItem]
  let isCommitting: Bool
  let onCommit: () -> Void
  var onAddMore: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  private var confirmedItems: [GroceryPendingItem] {
    items.filter(\.isConfirmed)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        HStack {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("Review Items")
              .font(.system(.title2, design: .serif, weight: .bold))
              .foregroundStyle(AppTheme.textPrimary)

            Text(
              "Adding \(confirmedItems.count) item\(confirmedItems.count == 1 ? "" : "s") to your kitchen"
            )
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
          isCommitting
            ? "Adding\u{2026}"
            : "Confirm & Add \(confirmedItems.count) Item\(confirmedItems.count == 1 ? "" : "s")",
          systemImage: "plus.circle.fill",
          isEnabled: !confirmedItems.isEmpty && !isCommitting
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

  // MARK: - Item Card

  private func groceryItemCard(item: GroceryPendingItem, index: Int) -> some View {
    let bindingItem = Binding(
      get: { items[safe: index] ?? item },
      set: { newValue in
        guard index < items.count else { return }
        items[index] = newValue
      }
    )

    return FLCard(tone: item.isConfirmed ? .success : .normal) {
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

            confidencePill(item.confidenceScore)
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

        HStack(spacing: AppTheme.Space.md) {
          HStack(spacing: AppTheme.Space.xs) {
            Text("Qty:")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)

            Text("\(Int(item.quantityGrams))g")
              .font(AppTheme.Typography.dataSmall)
              .foregroundStyle(AppTheme.textPrimary)
              .contentTransition(.numericText())
              .frame(minWidth: 36)

            Stepper(
              "",
              value: bindingItem.quantityGrams,
              in: 10...5000,
              step: 25
            )
            .labelsHidden()
            .fixedSize()
          }

          Spacer()

          Picker("Location", selection: bindingItem.storageLocation) {
            Text("Fridge").tag(InventoryStorageLocation.fridge)
            Text("Pantry").tag(InventoryStorageLocation.pantry)
            Text("Freezer").tag(InventoryStorageLocation.freezer)
          }
          .pickerStyle(.menu)
          .font(AppTheme.Typography.labelSmall)
          .tint(AppTheme.accent)
        }
      }
    }
  }

  private func confidencePill(_ confidence: Double) -> some View {
    let percentage = Int((confidence * 100).rounded())
    let kind: FLStatusPill.Kind =
      confidence >= 0.80 ? .positive : confidence >= 0.50 ? .warning : .neutral
    return FLStatusPill(text: "\(percentage)%", kind: kind)
  }
}

// MARK: - Safe Array Subscript

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
