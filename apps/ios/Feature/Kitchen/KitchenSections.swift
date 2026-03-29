import SwiftUI

// MARK: - Use Soon Section

struct KitchenUseSoonSection: View {
  let items: [InventoryActiveItem]

  var body: some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Use Soon",
          subtitle: "\(items.count) item\(items.count == 1 ? "" : "s") expiring",
          icon: "clock.badge.exclamationmark"
        )

        FLCard(tone: .warning) {
          VStack(spacing: AppTheme.Space.xs) {
            ForEach(items, id: \.id) { item in
              HStack {
                Text(item.ingredientName)
                  .font(AppTheme.Typography.bodyMedium)
                  .foregroundStyle(AppTheme.textPrimary)
                  .lineLimit(1)

                Spacer()

                if let days = item.daysUntilExpiry {
                  FLStatusPill(
                    text: expiryText(days: days),
                    kind: days <= 1 ? .warning : .neutral
                  )
                }
              }
              .padding(.vertical, AppTheme.Space.xxs)
            }
          }
        }
      }
    }
  }

  private func expiryText(days: Int) -> String {
    if days <= 0 { return "Today" }
    if days == 1 { return "1 day" }
    return "\(days) days"
  }
}

// MARK: - Needs Review Section

struct KitchenNeedsReviewSection: View {
  let items: [InventoryActiveItem]

  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulseActive = false

  var body: some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Needs Review",
          subtitle: "\(items.count) uncertain item\(items.count == 1 ? "" : "s")",
          icon: "exclamationmark.triangle"
        )

        FLCard(tone: .warm) {
          VStack(spacing: AppTheme.Space.sm) {
            ForEach(items, id: \.id) { item in
              HStack(spacing: AppTheme.Space.sm) {
                Circle()
                  .fill(AppTheme.dustyRose)
                  .frame(width: 8, height: 8)
                  .scaleEffect(pulseActive ? 1.3 : 1.0)

                VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
                  Text(item.ingredientName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                  Text("\(Int((item.averageConfidenceScore * 100).rounded()))% confidence")
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                Text(prefs.formatWeight(grams: item.totalRemainingGrams))
                  .font(AppTheme.Typography.dataSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
          }
        }
      }
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(AppMotion.micPulse.repeatForever(autoreverses: true)) {
          pulseActive = true
        }
      }
    }
  }
}

// MARK: - On Hand Section

struct KitchenOnHandSection: View {
  let groupedItems: [InventoryStorageLocation: [InventoryActiveItem]]
  let locationOrder: [InventoryStorageLocation]

  var body: some View {
    let populatedLocations = locationOrder.filter { location in
      guard let items = groupedItems[location] else { return false }
      return !items.isEmpty
    }

    if !populatedLocations.isEmpty {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("On Hand", icon: "refrigerator")

        ForEach(populatedLocations, id: \.self) { location in
          if let items = groupedItems[location] {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
              HStack(spacing: AppTheme.Space.xxs) {
                Image(systemName: location.icon)
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(AppTheme.textSecondary)
                Text(location.displayLabel)
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.textSecondary)
                Text("(\(items.count))")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
              }
              .padding(.top, AppTheme.Space.xs)

              ForEach(items, id: \.id) { item in
                KitchenItemRow(item: item)
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Kitchen Item Row

struct KitchenItemRow: View {
  let item: InventoryActiveItem

  @Environment(AppPreferencesStore.self) private var prefs

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Text(item.ingredientName)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .lineLimit(1)

      Spacer()

      Text(prefs.formatWeight(grams: item.totalRemainingGrams))
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText())

      if item.lotCount > 1 {
        Text("\(item.lotCount) lots")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
      }

      if let days = item.daysUntilExpiry, days <= 3 {
        Circle()
          .fill(days <= 1 ? AppTheme.accent : AppTheme.oat)
          .frame(width: 6, height: 6)
      }
    }
    .padding(.vertical, AppTheme.Space.xs)
    .padding(.horizontal, AppTheme.Space.md)
    .background(
      AppTheme.surfaceElevated,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.20), lineWidth: 1)
    )
  }
}

// MARK: - Quick Add Section

struct KitchenQuickAddSection: View {
  let onScanGroceries: () -> Void
  let onAddManual: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLSectionHeader("Add Items", icon: "plus.circle")

      HStack(spacing: AppTheme.Space.sm) {
        quickAddButton(
          icon: "camera.viewfinder",
          label: "Scan\nGroceries",
          action: onScanGroceries
        )
        quickAddButton(
          icon: "plus.circle",
          label: "Add\nManually",
          action: onAddManual
        )
        quickAddButton(
          icon: "doc.text.viewfinder",
          label: "Photo\nReceipt",
          action: {
            // TODO: Connect this action to the receipt-import capture flow.
          }
        )
      }
    }
  }

  private func quickAddButton(
    icon: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: AppTheme.Space.xs) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(AppTheme.accent)
        Text(label)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.md)
      .background(
        AppTheme.surfaceElevated,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
    .buttonStyle(FLPressableButtonStyle())
  }
}
