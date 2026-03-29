import SwiftUI

struct VirtualFridgeItemRow: View {
  let item: InventoryActiveItem

  @Environment(AppPreferencesStore.self) private var prefs

  var body: some View {
    FLCard {
      HStack(spacing: AppTheme.Space.sm) {
        locationIcon
          .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(item.ingredientName)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .fontWeight(.medium)
            .lineLimit(1)

          HStack(spacing: AppTheme.Space.xs) {
            Text(prefs.formatWeight(grams: item.totalRemainingGrams))
              .font(AppTheme.Typography.dataSmall)
              .foregroundStyle(AppTheme.textPrimary)
              .contentTransition(.numericText())

            if item.lotCount > 1 {
              Text("\(item.lotCount) lots")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }

          trustBadges
        }

        Spacer(minLength: AppTheme.Space.xs)

        VStack(alignment: .trailing, spacing: AppTheme.Space.xxs) {
          confidenceDot
          expiryLabel
        }
      }
    }
  }

  // MARK: - Location Icon

  private var locationIcon: some View {
    ZStack {
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(locationTint.opacity(0.10))
      Image(systemName: item.storageLocation.icon)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(locationTint)
    }
  }

  private var locationTint: Color {
    switch item.storageLocation {
    case .fridge: return AppTheme.sage
    case .pantry: return AppTheme.oat
    case .freezer: return AppTheme.accent
    case .unknown: return AppTheme.textSecondary
    }
  }

  // MARK: - Confidence

  private var confidenceDot: some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Circle()
        .fill(confidenceColor)
        .frame(width: 8, height: 8)
      Text("\(Int((item.averageConfidenceScore * 100).rounded()))%")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText())
    }
  }

  private var confidenceColor: Color {
    if item.averageConfidenceScore >= 0.8 { return AppTheme.sage }
    if item.averageConfidenceScore >= 0.5 { return AppTheme.oat }
    return AppTheme.dustyRose
  }

  // MARK: - Expiry

  @ViewBuilder
  private var expiryLabel: some View {
    if let days = item.daysUntilExpiry {
      Text(expiryText(days: days))
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(days <= 3 ? AppTheme.warning : AppTheme.textSecondary)
    } else {
      Text("No expiry")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
    }
  }

  private func expiryText(days: Int) -> String {
    if days <= 0 { return "Expires today" }
    if days == 1 { return "1 day left" }
    return "\(days) days left"
  }

  // MARK: - Trust Badges

  @ViewBuilder
  private var trustBadges: some View {
    let badges = activeBadges
    if !badges.isEmpty {
      HStack(spacing: AppTheme.Space.xxs) {
        ForEach(badges, id: \.self) { badge in
          FLStatusPill(text: badge.text, kind: badge.kind)
        }
      }
    }
  }

  private struct BadgeInfo: Hashable {
    let text: String
    let kind: FLStatusPill.Kind
  }

  private var activeBadges: [BadgeInfo] {
    var badges: [BadgeInfo] = []
    if item.isRecentlyAdded {
      badges.append(BadgeInfo(text: "New", kind: .positive))
    }
    if item.isLowStock {
      badges.append(BadgeInfo(text: "Low", kind: .warning))
    }
    if item.isExpiringSoon {
      badges.append(BadgeInfo(text: "Use soon", kind: .warning))
    }
    return badges
  }
}
