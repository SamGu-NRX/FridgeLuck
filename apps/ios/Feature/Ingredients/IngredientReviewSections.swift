import SwiftUI
import UIKit

struct IngredientReviewSummarySection: View {
  let confirmedCount: Int
  let categorizedConfirmedCount: Int
  let categorizedNeedsConfirmationCount: Int
  let categorizedPossibleCount: Int
  let unresolvedCount: Int
  let confirmationCompletion: Double
  let reduceMotion: Bool
  let confidencePillText: String
  let confidencePillKind: FLStatusPill.Kind
  let fridgeImage: UIImage?
  let onOpenFridgePhoto: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("\(confirmedCount) ingredient\(confirmedCount == 1 ? "" : "s") selected")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Confirm uncertain detections, then continue to recipe results.")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()

        if let fridgeImage {
          Button(action: onOpenFridgePhoto) {
            Image(uiImage: fridgeImage)
              .resizable()
              .scaledToFill()
              .frame(width: 48, height: 48)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                  .stroke(AppTheme.oat.opacity(0.35), lineWidth: 1)
              )
              .overlay(alignment: .bottomTrailing) {
                Image(systemName: "magnifyingglass")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(.white)
                  .padding(3)
                  .background(AppTheme.accent, in: Circle())
                  .offset(x: 3, y: 3)
              }
              .shadow(color: AppTheme.Shadow.color, radius: 4, x: 0, y: 2)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("View fridge photo")
        }
      }

      HStack(alignment: .top, spacing: AppTheme.Space.sm) {
        FLStatusPill(text: confidencePillText, kind: confidencePillKind)
      }

      HStack(spacing: AppTheme.Space.sm) {
        summaryCounter(
          label: "Auto",
          value: categorizedConfirmedCount,
          icon: "checkmark.circle.fill"
        )
        summaryCounter(
          label: "Confirm",
          value: categorizedNeedsConfirmationCount,
          icon: "questionmark.circle.fill"
        )
        summaryCounter(
          label: "Maybe",
          value: categorizedPossibleCount,
          icon: "sparkles"
        )
      }
      .id("confidenceLevels")
      .spotlightAnchor("confidenceLevels")

      if categorizedNeedsConfirmationCount > 0 {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          HStack {
            Text("Confirmation progress")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("\(Int((confirmationCompletion * 100).rounded()))%")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
          }

          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(AppTheme.textSecondary.opacity(0.16))
              Capsule()
                .fill(AppTheme.accent)
                .frame(width: geo.size.width * confirmationCompletion)
            }
            .animation(reduceMotion ? nil : AppMotion.quick, value: confirmationCompletion)
          }
          .frame(height: 7)
        }
      }
    }
  }

  private func summaryCounter(label: String, value: Int, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
      Text("\(label): \(value)")
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }
}

struct IngredientReviewNutritionSection: View {
  let nutritionLabelOutcome: NutritionLabelParseOutcome?

  var body: some View {
    Group {
      if let parsed = nutritionLabelOutcome?.parsed {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          FLSectionHeader(
            "Packaged Nutrition Parsed",
            subtitle: "OCR detected label values for this scan.",
            icon: "doc.text.magnifyingglass"
          )

          HStack(spacing: AppTheme.Space.md) {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text("\(Int(parsed.caloriesPerServing.rounded())) kcal")
                .font(AppTheme.Typography.displayCaption)
              Text("Per serving")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if let servingSize = parsed.servingSize {
              VStack(alignment: .trailing, spacing: AppTheme.Space.xxxs) {
                Text(servingSize)
                  .font(AppTheme.Typography.bodyMedium)
                Text("Serving size")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
          }

          if let servings = parsed.servingsPerContainer {
            Text("Servings per container: \(String(format: "%.1f", servings))")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
          }

          Text("Source: \(parsed.source) · Confidence: \(parsed.confidence.rawValue.capitalized)")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.bottom, AppTheme.Space.lg)
      } else if nutritionLabelOutcome?.hadNutritionKeywords == true {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          FLSectionHeader(
            "Nutrition Label Detected",
            subtitle: "Couldn't confidently parse calories/serving.",
            icon: "exclamationmark.triangle.fill"
          )
          Text("Try a closer image of the nutrition panel if you want packaged values.")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.bottom, AppTheme.Space.lg)
      }
    }
  }
}

struct IngredientReviewConfirmedSection: View {
  let detections: [Detection]
  let confirmedIds: Set<Int64>
  let onInfo: (Int64) -> Void
  let onToggle: (Int64) -> Void

  var body: some View {
    Group {
      if !detections.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("AUTO-DETECTED")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(detections) { detection in
              OrganicIngredientChip(
                label: detection.label,
                isSelected: confirmedIds.contains(detection.ingredientId),
                chipStyle: .confirmed,
                confidence: detection.confidence,
                onInfo: {
                  onInfo(detection.ingredientId)
                },
                action: {
                  onToggle(detection.ingredientId)
                }
              )
            }
          }
        }
      }
    }
  }
}

struct IngredientReviewNeedsConfirmationSection: View {
  let detections: [Detection]
  let selectedIngredientId: (Detection) -> Int64?
  let optionsForDetection: (Detection) -> [DetectionAlternative]
  let onChoose: (DetectionAlternative, Detection) -> Void
  let onChooseAnother: (Detection) -> Void
  let onClear: (Detection) -> Void
  let onInfo: (Detection) -> Void

  var body: some View {
    Group {
      if !detections.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          Text("NEEDS CONFIRMATION")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          ForEach(detections) { detection in
            confidenceRow(for: detection)
          }
        }
      }
    }
  }

  private func confidenceRow(for detection: Detection) -> some View {
    let options = optionsForDetection(detection)
    let bucket = ConfidenceRouter.bucket(for: detection)

    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(detection.label)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text(
            "\(ConfidenceRouter.label(for: bucket)) · \(Int((detection.confidence * 100).rounded())) score"
          )
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          Text(ConfidenceRouter.explanation(for: detection))
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        Button {
          onInfo(detection)
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
      }

      FlowLayout(spacing: AppTheme.Space.xs) {
        ForEach(options) { option in
          let isSelected = selectedIngredientId(detection) == option.ingredientId

          Button {
            onChoose(option, detection)
          } label: {
            HStack(spacing: AppTheme.Space.xs) {
              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(AppTheme.Typography.label)
                .foregroundStyle(isSelected ? AppTheme.positive : AppTheme.textSecondary)
                .animation(.default, value: isSelected)
              Text(option.label)
                .font(AppTheme.Typography.label)
                .lineLimit(1)
              if let confidence = option.confidence {
                Text("\(Int((confidence * 100).rounded()))%")
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .background(
              isSelected ? AppTheme.accent.opacity(0.18) : AppTheme.surfaceMuted
            )
            .clipShape(Capsule())
            .overlay(
              Capsule().stroke(
                isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.30),
                style: isSelected
                  ? StrokeStyle(lineWidth: 1) : StrokeStyle(lineWidth: 1, dash: [4, 3])
              )
            )
            .animation(.default, value: isSelected)
          }
          .buttonStyle(.plain)
        }
      }

      HStack {
        Button("Choose another") {
          onChooseAnother(detection)
        }
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.accent)

        Spacer()

        Button("Not this item") {
          onClear(detection)
        }
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
      }

      Divider()
        .foregroundStyle(AppTheme.oat.opacity(0.20))
    }
  }
}

struct IngredientReviewPossibleSection: View {
  let detections: [Detection]
  let confirmedIds: Set<Int64>
  let onInfo: (Int64) -> Void
  let onToggle: (Int64) -> Void

  var body: some View {
    Group {
      if !detections.isEmpty {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          Text("MAYBE")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(1.2)

          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(detections) { detection in
              OrganicIngredientChip(
                label: detection.label,
                isSelected: confirmedIds.contains(detection.ingredientId),
                chipStyle: .possible,
                confidence: detection.confidence,
                onInfo: {
                  onInfo(detection.ingredientId)
                },
                action: {
                  onToggle(detection.ingredientId)
                }
              )
            }
          }
        }
      }
    }
  }
}

// MARK: - Ingredient Chip

struct OrganicIngredientChip: View {
  let label: String
  let isSelected: Bool
  let chipStyle: ChipStyle
  let confidence: Float
  let onInfo: (() -> Void)?
  let action: () -> Void

  enum ChipStyle {
    case confirmed
    case possible

    var tint: Color {
      switch self {
      case .confirmed: return AppTheme.sage
      case .possible: return AppTheme.neutral
      }
    }

    var selectedTint: Color {
      switch self {
      case .confirmed: return AppTheme.sage
      case .possible: return AppTheme.accent
      }
    }
  }

  var body: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Button(action: action) {
        HStack(spacing: AppTheme.Space.xs) {
          Text(label)
            .font(
              chipStyle == .possible
                ? AppTheme.Typography.bodySmall : AppTheme.Typography.bodyMedium)
          if confidence < 0.65 {
            Text("\(Int(confidence * 100))%")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.chipVertical)
        .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
        .background(
          isSelected ? chipStyle.selectedTint.opacity(0.18) : chipStyle.tint.opacity(0.08),
          in: Capsule()
        )
        .overlay(
          Capsule().stroke(
            isSelected ? chipStyle.selectedTint.opacity(0.40) : chipStyle.tint.opacity(0.18),
            lineWidth: 1
          )
        )
        .animation(.default, value: isSelected)
        .opacity(chipStyle == .possible ? 0.85 : 1.0)
      }
      .buttonStyle(.plain)

      if let onInfo {
        Button(action: onInfo) {
          Image(systemName: "info.circle")
            .foregroundStyle(AppTheme.textSecondary)
            .font(.system(size: 13))
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Bottom Bar

struct IngredientReviewBottomBar: View {
  let confirmedCount: Int
  let unresolvedCount: Int
  let reduceMotion: Bool
  let onFindRecipes: () -> Void

  var body: some View {
    FLActionBar {
      if confirmedCount == 0 {
        Text("Pick at least one ingredient to continue to recipe matching.")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AppTheme.Space.page)
      }

      if unresolvedCount > 0 {
        Text(
          "\(unresolvedCount) uncertain item\(unresolvedCount == 1 ? "" : "s") remain. You can continue, but quality may improve after confirmation."
        )
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Space.page)
      }

      FLPrimaryButton(
        "Find Recipes with \(confirmedCount) Ingredient\(confirmedCount == 1 ? "" : "s")",
        systemImage: "fork.knife",
        isEnabled: confirmedCount > 0
      ) {
        onFindRecipes()
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .animation(reduceMotion ? nil : AppMotion.gentle, value: unresolvedCount)
  }
}
