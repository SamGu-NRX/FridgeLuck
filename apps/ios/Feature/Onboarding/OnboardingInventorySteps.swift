import SwiftUI
import UIKit

// MARK: - Step 1: Virtual Fridge Intro

struct OnboardingVirtualFridgeIntroStep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(spacing: AppTheme.Space.xl) {
        Spacer(minLength: AppTheme.Space.lg)

        ZStack {
          Circle()
            .fill(
              RadialGradient(
                colors: [AppTheme.sage.opacity(0.22), AppTheme.sage.opacity(0.04)],
                center: .center,
                startRadius: 16,
                endRadius: 80
              )
            )
            .frame(width: 148, height: 148)

          Image(systemName: "refrigerator.fill")
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(AppTheme.sage)
        }
        .inventoryStagger(index: 0, appeared: appeared)

        VStack(spacing: AppTheme.Space.md) {
          Text("Your Virtual Fridge")
            .font(.system(.title, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .inventoryStagger(index: 1, appeared: appeared)

          Text(
            "We\u{2019}ll scan your kitchen and build an inventory.\nWe estimate \u{2014} you confirm."
          )
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
          .inventoryStagger(index: 2, appeared: appeared)
        }

        VStack(spacing: AppTheme.Space.sm) {
          featurePill(icon: "leaf.fill", text: "Track freshness", index: 3)
          featurePill(icon: "tray.full.fill", text: "Know what\u{2019}s on hand", index: 4)
          featurePill(icon: "fork.knife", text: "Log meals accurately", index: 5)
        }
        .padding(.top, AppTheme.Space.sm)

        Spacer(minLength: AppTheme.Space.xl)
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
    .task {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) {
          appeared = true
        }
      }
    }
  }

  private func featurePill(icon: String, text: String, index: Int) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(AppTheme.sage)
        .frame(width: 28, height: 28)
        .background(AppTheme.sage.opacity(0.12), in: Circle())

      Text(text)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
    .inventoryStagger(index: index, appeared: appeared)
  }
}

// MARK: - Step 2: Fridge Capture

struct OnboardingFridgeCaptureStep: View {
  @Binding var capturedImages: [UIImage]

  var body: some View {
    OnboardingKitchenCaptureStep(
      configuration: .fridge,
      capturedImages: $capturedImages
    )
  }
}

// MARK: - Step 3: Pantry Capture

struct OnboardingPantryCaptureStep: View {
  @Binding var capturedImages: [UIImage]

  var body: some View {
    OnboardingKitchenCaptureStep(
      configuration: .pantry,
      capturedImages: $capturedImages
    )
  }
}

// MARK: - Step 4: Kitchen Review

struct OnboardingKitchenReviewStep: View {
  let fridgeCapturedImages: [UIImage]
  let pantryCapturedImages: [UIImage]
  @Binding var detections: [Detection]
  @Binding var confirmedIds: Set<Int64>
  @Binding var isAnalyzing: Bool
  let onConfirm: () -> Void

  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var demoData: OnboardingKitchenDemoDetections.KitchenDetectionSet?

  private var fridgeDetections: [Detection] {
    demoData?.fridgeItems ?? []
  }

  private var pantryDetections: [Detection] {
    demoData?.pantryItems ?? []
  }

  private var allDetections: [Detection] {
    fridgeDetections + pantryDetections
  }

  private let placeholderWidths: [CGFloat] = [140, 116, 128, 102]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("Review Your Kitchen")
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .inventoryStagger(index: 0, appeared: appeared)

          Text("Confirm what we found, adjust anything that\u{2019}s off.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .inventoryStagger(index: 1, appeared: appeared)
        }

        if !fridgeCapturedImages.isEmpty || !pantryCapturedImages.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Space.xs) {
              ForEach(
                Array((fridgeCapturedImages + pantryCapturedImages).prefix(6).enumerated()),
                id: \.offset
              ) { _, image in
                Image(uiImage: image)
                  .resizable()
                  .scaledToFill()
                  .frame(width: 56, height: 56)
                  .clipShape(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                      .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
                  )
              }
            }
          }
          .inventoryStagger(index: 2, appeared: appeared)
        }

        if isAnalyzing {
          analysingPlaceholder
            .inventoryStagger(index: 3, appeared: appeared)
        } else if allDetections.isEmpty {
          FLEmptyState(
            title: "No items detected",
            message: "You can add inventory anytime from the scan orb.",
            systemImage: "tray"
          )
          .inventoryStagger(index: 3, appeared: appeared)
        } else {
          if !fridgeDetections.isEmpty {
            detectionSection(
              title: "Fridge",
              icon: "refrigerator.fill",
              iconColor: AppTheme.sage,
              detections: fridgeDetections,
              location: .fridge,
              staggerBase: 3
            )
          }

          if !pantryDetections.isEmpty {
            detectionSection(
              title: "Pantry",
              icon: "cabinet.fill",
              iconColor: AppTheme.accent,
              detections: pantryDetections,
              location: .pantry,
              staggerBase: 3 + (fridgeDetections.isEmpty ? 0 : 1)
            )
          }

          let confirmedCount = confirmedIds.count
          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(AppTheme.sage)
            Text("\(confirmedCount) of \(allDetections.count) items confirmed")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
              .contentTransition(.numericText())
          }
          .padding(.top, AppTheme.Space.xs)

          FLPrimaryButton(
            "Add to My Kitchen",
            systemImage: "plus.circle.fill",
            isEnabled: !confirmedIds.isEmpty
          ) {
            onConfirm()
          }
          .padding(.top, AppTheme.Space.sm)
        }

        Color.clear
          .frame(height: AppTheme.Space.lg)
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
    }
    .task {
      guard demoData == nil else { return }

      isAnalyzing = true
      do {
        try await Task.sleep(for: reduceMotion ? .milliseconds(400) : .milliseconds(1300))
      } catch {
        return
      }

      let data = OnboardingKitchenDemoDetections.load()
      demoData = data

      let allItems = data.fridgeItems + data.pantryItems
      let highConfidence = allItems.filter { $0.confidence >= 0.80 }
      confirmedIds = Set(highConfidence.map(\.ingredientId))
      detections = allItems

      withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
        isAnalyzing = false
      }

      if !appeared {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.staggerEntrance) {
            appeared = true
          }
        }
      }
    }
    .onAppear {
      if !appeared, demoData != nil {
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.staggerEntrance) {
            appeared = true
          }
        }
      }
    }
  }

  // MARK: - Detection Section

  private func detectionSection(
    title: String,
    icon: String,
    iconColor: Color,
    detections: [Detection],
    location: InventoryStorageLocation,
    staggerBase: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(iconColor)
        Text(title)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text("\(detections.count) items")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .inventoryStagger(index: staggerBase, appeared: appeared)

      VStack(spacing: AppTheme.Space.xs) {
        ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
          detectionItemRow(
            detection: detection,
            location: location,
            staggerIndex: staggerBase + 1 + min(index, 8)
          )
        }
      }
    }
  }

  private func detectionItemRow(
    detection: Detection,
    location: InventoryStorageLocation,
    staggerIndex: Int
  ) -> some View {
    let isConfirmed = confirmedIds.contains(detection.ingredientId)
    let estimatedGrams = InventoryIntakeService.estimateGrams(forName: detection.label)

    return FLCard(tone: isConfirmed ? .success : .normal) {
      HStack(spacing: AppTheme.Space.sm) {
        Button {
          withAnimation(reduceMotion ? nil : AppMotion.gentle) {
            if isConfirmed {
              confirmedIds.remove(detection.ingredientId)
            } else {
              confirmedIds.insert(detection.ingredientId)
            }
          }
        } label: {
          Image(systemName: isConfirmed ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(isConfirmed ? AppTheme.sage : AppTheme.oat.opacity(0.5))
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isConfirmed)
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(detection.label)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textPrimary)

          HStack(spacing: AppTheme.Space.xs) {
            Text("~\(Int(estimatedGrams))g")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)

            confidencePill(detection.confidence)
          }
        }

        Spacer()
      }
    }
    .inventoryStagger(index: staggerIndex, appeared: appeared)
  }

  private func confidencePill(_ confidence: Float) -> some View {
    let percentage = Int((confidence * 100).rounded())
    let kind: FLStatusPill.Kind = confidence >= 0.80 ? .positive : .warning
    return FLStatusPill(text: "\(percentage)%", kind: kind)
  }

  // MARK: - Analyzing Placeholder

  private var analysingPlaceholder: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ProgressView()
        .controlSize(.large)
        .tint(AppTheme.accent)

      VStack(spacing: AppTheme.Space.xs) {
        Text("Scanning your kitchen\u{2026}")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("Identifying ingredients and estimating quantities.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        ForEach(Array(placeholderWidths.enumerated()), id: \.offset) { _, width in
          shimmerRow(width: width)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xl)
  }

  private func shimmerRow(width: CGFloat) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(AppTheme.oat.opacity(0.15))
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 4) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(AppTheme.oat.opacity(0.12))
          .frame(width: width, height: 12)

        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(AppTheme.oat.opacity(0.08))
          .frame(width: 50, height: 10)
      }

      Spacer()

      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(AppTheme.oat.opacity(0.10))
        .frame(width: 40, height: 18)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.15), lineWidth: 1)
    )
  }
}
