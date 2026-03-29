import SwiftUI

struct PantryAssumptionsSection: View {
  let assumptions: [PantryAssumptionDisplay]
  let onCycleTier: (Int64) -> Void
  let onRemove: (Int64) -> Void
  let onAddStaple: () -> Void

  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.gentle) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "tray.full")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
          Text("Always Have")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
      }
      .buttonStyle(.plain)

      if isExpanded {
        if assumptions.isEmpty {
          VStack(spacing: AppTheme.Space.sm) {
            Text("Set up your pantry staples")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
            Text(
              "Tell us what you always keep on hand (salt, oil, spices) so recipes can assume these are available."
            )
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)

            FLSecondaryButton("Add Staples", systemImage: "plus.circle") {
              onAddStaple()
            }
          }
          .padding(AppTheme.Space.md)
          .frame(maxWidth: .infinity)
          .background(
            AppTheme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
          )
        } else {
          tierGroup(
            title: "Always have",
            items: assumptions.filter { $0.tier == .alwaysHave },
            tintColor: AppTheme.sage
          )
          tierGroup(
            title: "Usually have",
            items: assumptions.filter { $0.tier == .usuallyHave },
            tintColor: AppTheme.oat
          )

          FLSecondaryButton("Add Staple", systemImage: "plus.circle") {
            onAddStaple()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func tierGroup(
    title: String,
    items: [PantryAssumptionDisplay],
    tintColor: Color
  ) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Text(title)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .textCase(.uppercase)
          .kerning(0.8)

        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(items, id: \.ingredientId) { item in
            Button {
              AppPreferencesStore.haptic(.light)
              onCycleTier(item.ingredientId)
            } label: {
              Text(item.ingredientName)
                .font(AppTheme.Typography.label)
                .foregroundStyle(tintColor)
                .padding(.horizontal, AppTheme.Space.sm)
                .padding(.vertical, AppTheme.Space.chipVertical)
                .background(tintColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "\(item.ingredientName), \(item.tier == .alwaysHave ? "always have" : "usually have"). Tap to change tier."
            )
            .contextMenu {
              Button("Remove", role: .destructive) {
                onRemove(item.ingredientId)
              }
              .accessibilityLabel("Remove \(item.ingredientName) from pantry staples")
            }
          }
        }
      }
    }
  }
}

struct PantryAssumptionDisplay: Sendable {
  let ingredientId: Int64
  let ingredientName: String
  let tier: PantryAssumption.PantryTier
}
