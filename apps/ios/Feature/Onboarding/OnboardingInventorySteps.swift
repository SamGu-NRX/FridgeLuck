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
  @Binding var photos: [FLCapturedPhoto]

  var body: some View {
    OnboardingKitchenCaptureStep(
      configuration: .fridge,
      photos: $photos
    )
  }
}

// MARK: - Step 3: Pantry Capture

struct OnboardingPantryCaptureStep: View {
  @Binding var photos: [FLCapturedPhoto]

  var body: some View {
    OnboardingKitchenCaptureStep(
      configuration: .pantry,
      photos: $photos
    )
  }
}

// MARK: - Step 4: Kitchen Review

/// Scans the photos from the two capture steps and lets the user choose what goes into their
/// Kitchen. Skipped photos, scans that find nothing and failed scans each say so; the review
/// never fills in items the photos didn't show.
struct OnboardingKitchenReviewStep: View {
  private enum Phase {
    case scanning
    case ready(OnboardingKitchenReviewState)
  }

  let fridgePhotos: [FLCapturedPhoto]
  let pantryPhotos: [FLCapturedPhoto]
  @Binding var scan: OnboardingKitchenScanSession?
  @Binding var confirmedIds: Set<Int64>
  /// Writes the selection through inventory intake, then moves on.
  let onConfirm: () -> Void
  /// Moves on without touching the Kitchen.
  let onSkip: () -> Void

  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var resultsAppeared = false
  @State private var isScanning = false
  /// 0 scans new photos when the step appears; each Try Again increments it to rescan the
  /// locations whose scan failed.
  @State private var scanRequest = 0
  @AccessibilityFocusState private var isHeadingFocused: Bool

  private let placeholderWidths: [CGFloat] = [140, 116, 128, 102]

  private var hasPhotos: Bool {
    !fridgePhotos.isEmpty || !pantryPhotos.isEmpty
  }

  private var phase: Phase {
    guard hasPhotos else { return .ready(.nothingCaptured) }
    guard !isScanning, let scan,
      scan.covers(fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos)
    else { return .scanning }
    return .ready(scan.reviewState)
  }

  private var subtitle: String? {
    switch phase {
    case .scanning:
      return "Confirm what we found, adjust anything that\u{2019}s off."
    case .ready(.review):
      return "Items we\u{2019}re sure of are checked. Tap anything else you have."
    case .ready:
      return nil
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text("Review Your Kitchen")
            .font(.system(.title2, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($isHeadingFocused)
            .inventoryStagger(index: 0, appeared: appeared)

          if let subtitle {
            Text(subtitle)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
              .inventoryStagger(index: 1, appeared: appeared)
          }
        }

        if hasPhotos {
          photoStrip
            .inventoryStagger(index: 2, appeared: appeared)
        }

        switch phase {
        case .scanning:
          analysingPlaceholder
            .inventoryStagger(index: 3, appeared: appeared)
            .transition(.opacity)
        case .ready(let state):
          content(for: state)
            .transition(.opacity)
        }

        Color.clear
          .frame(height: AppTheme.Space.lg)
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
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
    .task(id: scanRequest) {
      await runScan()
    }
  }

  // MARK: - Scanning

  private func runScan() async {
    let retrying = scanRequest > 0
    let previous = scan
    let isSamePhotos =
      previous?.covers(fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos) == true
    let startedAt = Date()

    if hasPhotos && (!isSamePhotos || retrying) {
      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        isScanning = true
        resultsAppeared = false
      }
    }

    let vision = deps.visionService
    let next = await OnboardingKitchenScanner.update(
      fridgePhotos: fridgePhotos,
      pantryPhotos: pantryPhotos,
      previous: previous,
      selection: confirmedIds,
      retryFailed: retrying
    ) { inputs in
      try await vision.scan(inputs: inputs).detections
    }
    guard !Task.isCancelled else { return }

    if let next {
      if hasPhotos {
        await holdAnalyzingState(since: startedAt)
        guard !Task.isCancelled else { return }
      }

      confirmedIds = next.selection
      withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
        scan = next.session
        isScanning = false
      }
      announce(next.session.reviewState, selectedCount: next.selection.count)
    } else {
      isScanning = false
    }

    if reduceMotion {
      resultsAppeared = true
    } else {
      withAnimation(AppMotion.staggerEntrance) {
        resultsAppeared = true
      }
    }
  }

  /// The results replace the placeholder in place, so VoiceOver hears the outcome and starts
  /// from the heading. High priority keeps the focus move from cutting the announcement off.
  private func announce(_ state: OnboardingKitchenReviewState, selectedCount: Int) {
    isHeadingFocused = true
    var message = AttributedString(
      OnboardingKitchenReview.announcement(for: state, selectedCount: selectedCount))
    message.accessibilitySpeechAnnouncementPriority = .high
    AccessibilityNotification.Announcement(message).post()
  }

  /// Same floor as `ScanView.processImage()`, so a fast scan doesn't flash the placeholder.
  private func holdAnalyzingState(since startedAt: Date) async {
    let minimum: TimeInterval = reduceMotion ? 0.35 : 1.3
    let remaining = minimum - Date().timeIntervalSince(startedAt)
    guard remaining > 0 else { return }
    try? await Task.sleep(for: .seconds(remaining))
  }

  private func retryFailedScans() {
    scanRequest += 1
  }

  // MARK: - Content

  @ViewBuilder
  private func content(for state: OnboardingKitchenReviewState) -> some View {
    switch state {
    case .nothingCaptured:
      emptyState(
        title: "No photos to scan",
        message: "You can add ingredients from Kitchen any time.",
        systemImage: "camera"
      )

    case .nothingFound:
      emptyState(
        title: "No ingredients found",
        message:
          "We didn\u{2019}t find ingredients in these photos. You can add them from Kitchen any time.",
        systemImage: "tray"
      )

    case .failed:
      VStack(spacing: AppTheme.Space.md) {
        FLEmptyState(
          title: "Couldn\u{2019}t read your photos",
          message: "Try again, or continue and add ingredients from Kitchen later.",
          systemImage: "exclamationmark.triangle",
          actionTitle: "Try Again",
          action: retryFailedScans
        )
        .frame(maxWidth: .infinity)
        .inventoryStagger(index: 0, appeared: resultsAppeared)

        continueButton
          .inventoryStagger(index: 1, appeared: resultsAppeared)
      }

    case .review(let fridge, let pantry):
      reviewContent(fridge: fridge, pantry: pantry)
    }
  }

  private func emptyState(title: String, message: String, systemImage: String) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      FLEmptyState(title: title, message: message, systemImage: systemImage)
        .frame(maxWidth: .infinity)
        .inventoryStagger(index: 0, appeared: resultsAppeared)

      continueButton
        .inventoryStagger(index: 1, appeared: resultsAppeared)
    }
  }

  private var continueButton: some View {
    FLPrimaryButton("Continue", systemImage: "arrow.right") {
      onSkip()
    }
  }

  private func reviewContent(
    fridge: OnboardingKitchenSectionContent,
    pantry: OnboardingKitchenSectionContent
  ) -> some View {
    let shownIDs = Set((fridge.detections + pantry.detections).map(\.ingredientId))
    let selectedCount = confirmedIds.intersection(shownIDs).count
    // Section header, then up to nine staggered rows, per visible section.
    let pantryStaggerBase = isVisible(fridge) ? 2 + min(fridge.detections.count, 8) : 0
    let footerStaggerIndex =
      isVisible(pantry)
      ? pantryStaggerBase + 2 + min(pantry.detections.count, 8) : pantryStaggerBase

    return VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      locationSection(
        title: "Fridge",
        icon: "refrigerator.fill",
        iconColor: AppTheme.sage,
        content: fridge,
        staggerBase: 0
      )

      locationSection(
        title: "Pantry",
        icon: "cabinet.fill",
        iconColor: AppTheme.accent,
        content: pantry,
        staggerBase: pantryStaggerBase
      )

      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(AppTheme.sage)
            .accessibilityHidden(true)
          Text("\(selectedCount) of \(shownIDs.count) selected")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .contentTransition(.numericText())
        }
        .padding(.top, AppTheme.Space.xs)

        // With nothing selected this still goes through intake: on a revisit it removes what
        // an earlier visit added, which is what an empty selection means.
        FLPrimaryButton(
          selectedCount > 0 ? "Add to My Kitchen" : "Continue Without Adding",
          systemImage: selectedCount > 0 ? "plus.circle.fill" : "arrow.right"
        ) {
          onConfirm()
        }
        .padding(.top, AppTheme.Space.sm)
      }
      .inventoryStagger(index: footerStaggerIndex, appeared: resultsAppeared)
    }
  }

  // MARK: - Location Section

  private func isVisible(_ content: OnboardingKitchenSectionContent) -> Bool {
    switch content {
    case .notCaptured: return false
    case .items(let detections): return !detections.isEmpty
    case .failed, .nothingFound: return true
    }
  }

  @ViewBuilder
  private func locationSection(
    title: String,
    icon: String,
    iconColor: Color,
    content: OnboardingKitchenSectionContent,
    staggerBase: Int
  ) -> some View {
    if isVisible(content) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(iconColor)
            .accessibilityHidden(true)
          Text(title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          if case .items(let detections) = content {
            Text("\(detections.count) items")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
        .inventoryStagger(index: staggerBase, appeared: resultsAppeared)

        switch content {
        case .items(let detections):
          VStack(spacing: AppTheme.Space.xs) {
            ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
              detectionItemRow(
                detection: detection,
                staggerIndex: staggerBase + 1 + min(index, 8)
              )
            }
          }

        case .nothingFound:
          Text("No ingredients found in these photos.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .inventoryStagger(index: staggerBase + 1, appeared: resultsAppeared)

        case .failed:
          failedLocationNotice(title: title)
            .inventoryStagger(index: staggerBase + 1, appeared: resultsAppeared)

        case .notCaptured:
          EmptyView()
        }
      }
    }
  }

  /// One location's scan failed while the other found items. Those items stay reviewable;
  /// this location can be retried on its own.
  private func failedLocationNotice(title: String) -> some View {
    FLCard(tone: .warning) {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(AppTheme.warning)
          .accessibilityHidden(true)

        Text("Couldn\u{2019}t read your \(title.lowercased()) photos.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: AppTheme.Space.xs)

        Button(action: retryFailedScans) {
          Text("Try Again")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(FLPressableButtonStyle())
        .accessibilityLabel("Try reading your \(title.lowercased()) photos again")
      }
    }
  }

  private func detectionItemRow(
    detection: Detection,
    staggerIndex: Int
  ) -> some View {
    let isConfirmed = confirmedIds.contains(detection.ingredientId)
    let estimatedGrams = Int(InventoryIntakeService.estimateGrams(forName: detection.label))
    let percentage = Int((detection.confidence * 100).rounded())
    let bucket = ConfidenceRouter.bucket(for: detection)

    return Button {
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        if isConfirmed {
          confirmedIds.remove(detection.ingredientId)
        } else {
          confirmedIds.insert(detection.ingredientId)
        }
      }
    } label: {
      FLCard(tone: isConfirmed ? .success : .normal) {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isConfirmed ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(isConfirmed ? AppTheme.sage : AppTheme.oat.opacity(0.5))
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isConfirmed)

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(detection.label)
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: AppTheme.Space.xs) {
              Text("~\(estimatedGrams)g")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)

              FLStatusPill(text: "\(percentage)%", kind: pillKind(for: bucket))
            }
          }

          Spacer()
        }
      }
    }
    .buttonStyle(FLPressableButtonStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(detection.label), about \(estimatedGrams) grams")
    .accessibilityValue("\(percentage) percent match, \(isConfirmed ? "selected" : "not selected")")
    .accessibilityAddTraits(isConfirmed ? .isSelected : [])
    .accessibilityHint(isConfirmed ? "Removes it from what you add." : "Adds it to your Kitchen.")
    .inventoryStagger(index: staggerIndex, appeared: resultsAppeared)
  }

  /// Colours follow `ConfidenceRouter`'s buckets, the same split that decides preselection.
  private func pillKind(for bucket: ConfidenceBucket) -> FLStatusPill.Kind {
    switch bucket {
    case .auto: return .positive
    case .confirm: return .warning
    case .possible: return .neutral
    }
  }

  // MARK: - Photos

  private var photoStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: AppTheme.Space.xs) {
        ForEach(Array((fridgePhotos + pantryPhotos).prefix(6))) { photo in
          Image(uiImage: photo.image)
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
            .accessibilityHidden(true)
        }
      }
    }
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
      .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xl)
    .accessibilityElement(children: .combine)
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
