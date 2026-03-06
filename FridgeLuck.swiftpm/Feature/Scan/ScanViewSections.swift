import SwiftUI
import UIKit

struct ScanArcStageIndicator: View {
  let stageProgress: Double
  let stageName: String
  let stageIndex: Int
  let reduceMotion: Bool

  var body: some View {
    HStack(spacing: AppTheme.Space.lg) {
      FLArcIndicator(
        progress: stageProgress,
        steps: 3,
        size: 56
      )
      .frame(width: 72, height: 56, alignment: .center)
      .padding(.leading, AppTheme.Space.xs)
      .animation(reduceMotion ? nil : AppMotion.gentle, value: stageProgress)

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(stageName)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Step \(stageIndex) of 3")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
  }
}

struct ScanLiveCapturePrompt: View {
  let capturedShotsCount: Int
  let isCameraPermissionDenied: Bool
  let isCameraUnavailable: Bool
  let onOpenCamera: () -> Void
  let onOpenLibrary: () -> Void
  let onOpenSettings: () -> Void
  let onManualEntry: () -> Void

  var body: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 72, weight: .thin))
        .foregroundStyle(AppTheme.accent.opacity(0.7))
        .padding(AppTheme.Space.xl)
        .background(
          Circle()
            .fill(AppTheme.accent.opacity(0.06))
            .frame(width: 160, height: 160)
        )

      VStack(spacing: AppTheme.Space.sm) {
        Text("Photograph your ingredients")
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text("Close framing improves ingredient matching and recipe quality.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
        Text("Best results: take 2-3 close shots of ingredient groups.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLPrimaryButton("Open Camera", systemImage: "camera.fill", action: onOpenCamera)
        FLSecondaryButton(
          "Choose from Library", systemImage: "photo.on.rectangle", action: onOpenLibrary)

        Button(action: onManualEntry) {
          Label("Add Ingredients Manually", systemImage: "plus.circle")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, AppTheme.Space.xs)
      }

      if capturedShotsCount > 0 {
        Text("Captured shots: \(capturedShotsCount)/3")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      if isCameraPermissionDenied {
        FLCard(tone: .warning) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text("Camera permission is off")
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
            Text("Use photo library or manual ingredients to finish without camera access.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: AppTheme.Space.sm) {
              FLSecondaryButton(
                "Use Library", systemImage: "photo.on.rectangle", action: onOpenLibrary)
              FLSecondaryButton(
                "Open Settings", systemImage: "gearshape", action: onOpenSettings)
              FLSecondaryButton("Manual", systemImage: "plus.circle", action: onManualEntry)
            }
          }
        }
      }

      if isCameraUnavailable {
        Text("Camera unavailable on this device. Library and manual entry are ready.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
  }
}

struct ScanDemoCapturePreview: View {
  let capturedImage: UIImage?
  let entryMode: ScanView.EntryMode
  let fallbackStateText: String?
  let scanDiagnostics: ScanDiagnostics?

  var body: some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        Group {
          if let capturedImage {
            Image(uiImage: capturedImage)
              .resizable()
              .scaledToFill()
          } else {
            LinearGradient(
              colors: [AppTheme.deepOliveLight, AppTheme.deepOlive],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          LinearGradient(
            colors: [Color.black.opacity(0.04), Color.black.opacity(0.20)],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      }
      .frame(height: 260)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.32), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 10, x: 0, y: 3)

      VStack(spacing: AppTheme.Space.xs) {
        Text("Demo frame loaded")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Text(
          entryMode == .judgePath
            ? "Judge flow: demo photo, review, and best recipe."
            : "Running the same scan path: capture, analyze, then review."
        )
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)

        if let fallbackStateText {
          Text(fallbackStateText)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
            .multilineTextAlignment(.center)
            .padding(.top, AppTheme.Space.xxs)
        }

        if let scanDiagnostics {
          Text(
            "Scan \(scanDiagnostics.elapsedMs)ms · auto \(scanDiagnostics.bucketCounts.auto), confirm \(scanDiagnostics.bucketCounts.confirm), maybe \(scanDiagnostics.bucketCounts.possible)"
          )
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
        }
      }
    }
  }
}

struct ScanAnalyzingView: View {
  let capturedImage: UIImage?
  let fallbackStateText: String?
  let reduceMotion: Bool
  var title: String = "Scanning your fridge"
  var subtitle: String = "Finding ingredients and preparing your luck-based recipe set."

  var body: some View {
    VStack(spacing: AppTheme.Space.lg) {
      ZStack {
        backgroundImage
        ScanSweepOverlay(isAnimating: !reduceMotion)
      }
      .frame(height: 300)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
      )

      VStack(spacing: AppTheme.Space.sm) {
        Text(title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
        Text(subtitle)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(3)
          .multilineTextAlignment(.center)
        if let fallbackStateText {
          Text(fallbackStateText)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.accent)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, AppTheme.Space.md)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var backgroundImage: some View {
    if let capturedImage {
      Image(uiImage: capturedImage)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          Color.black.opacity(0.24)
        }
    } else {
      LinearGradient(
        colors: [AppTheme.deepOliveLight, AppTheme.deepOlive],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .overlay {
        Image(systemName: "camera.macro")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(AppTheme.surface.opacity(0.75))
      }
    }
  }
}

struct ScanErrorView: View {
  let capturedImage: UIImage?
  let errorMessage: String?
  let onManualEntry: () -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: AppTheme.Space.lg) {
      if let capturedImage {
        Image(uiImage: capturedImage)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 190)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
      }

      VStack(spacing: AppTheme.Space.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.accent)

        Text("Scan needs another pass")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        if let errorMessage {
          Text(errorMessage)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }

        Text("You can retry, or continue by manually picking ingredients.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: AppTheme.Space.sm) {
        FLPrimaryButton(
          "Add Ingredients Manually", systemImage: "plus.circle.fill", action: onManualEntry)
        FLSecondaryButton("Retry Scan", systemImage: "arrow.clockwise", action: onRetry)
      }
    }
  }
}
