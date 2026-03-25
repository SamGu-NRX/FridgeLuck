import SwiftUI
import UIKit

struct CookingCelebrationHeaderSection: View {
  let appeared: Bool
  let recipeTitle: String

  var body: some View {
    VStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "frying.pan.fill")
        .font(.system(size: 44))
        .foregroundStyle(AppTheme.accent)
        .scaleEffect(appeared ? 1 : 0.5)
        .opacity(appeared ? 1 : 0)

      Text("Well Done!")
        .font(AppTheme.Typography.displayLarge)
        .foregroundStyle(AppTheme.textPrimary)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)

      Text(recipeTitle)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }
    .padding(.bottom, AppTheme.Space.sm)
  }
}

struct CookingCelebrationRatingSection: View {
  @Binding var rating: Int
  let ratingLabel: String
  let appeared: Bool
  let reduceMotion: Bool

  var body: some View {
    FLCard(tone: .warm) {
      VStack(spacing: AppTheme.Space.sm) {
        Text("How was it?")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        FLStarRating(rating: $rating, size: 32)

        if rating > 0 {
          Text(ratingLabel)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      }
      .frame(maxWidth: .infinity)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.06), value: appeared)
  }
}

struct CookingCelebrationServingSection: View {
  @Binding var servings: Int
  let appeared: Bool
  let reduceMotion: Bool

  var body: some View {
    FLCard(tone: .warm) {
      FLServingStepper(servings: $servings, label: "Servings eaten")
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.12), value: appeared)
  }
}

struct CookingCelebrationMacroSection: View {
  let baseMacros: RecipeMacros
  let scaledCalories: Double
  let scaledProtein: Double
  let scaledCarbs: Double
  let scaledFat: Double
  let caloriePct: Double
  let proteinPct: Double
  let carbsPct: Double
  let fatPct: Double
  let appeared: Bool
  let reduceMotion: Bool

  var body: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        FLSectionHeader("Nutrition", icon: "chart.pie.fill")

        HStack(spacing: AppTheme.Space.lg) {
          ZStack {
            FLMacroRing(
              proteinPct: baseMacros.macroSplit.proteinPct,
              carbsPct: baseMacros.macroSplit.carbsPct,
              fatPct: baseMacros.macroSplit.fatPct,
              size: 100,
              lineWidth: 10
            )

            VStack(spacing: 2) {
              Text("\(Int(scaledCalories.rounded()))")
                .font(AppTheme.Typography.dataMedium)
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
              Text("kcal")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }

          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            CookingCelebrationMacroRow(
              label: "Protein",
              grams: scaledProtein,
              pctOfDaily: proteinPct,
              color: AppTheme.sage,
              reduceMotion: reduceMotion
            )
            CookingCelebrationMacroRow(
              label: "Carbs",
              grams: scaledCarbs,
              pctOfDaily: carbsPct,
              color: AppTheme.oat,
              reduceMotion: reduceMotion
            )
            CookingCelebrationMacroRow(
              label: "Fat",
              grams: scaledFat,
              pctOfDaily: fatPct,
              color: AppTheme.accentLight,
              reduceMotion: reduceMotion
            )
          }
        }

        VStack(spacing: AppTheme.Space.xxs) {
          HStack {
            Text("Daily calorie goal")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("\(Int((caloriePct * 100).rounded()))%")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.accent)
              .contentTransition(.numericText())
          }
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(AppTheme.surfaceMuted)
              Capsule()
                .fill(AppTheme.accent)
                .frame(width: geo.size.width * caloriePct)
                .animation(reduceMotion ? nil : AppMotion.counterReveal, value: caloriePct)
            }
          }
          .frame(height: 6)
        }
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.18), value: appeared)
  }
}

private struct CookingCelebrationMacroRow: View {
  let label: String
  let grams: Double
  let pctOfDaily: Double
  let color: Color
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      HStack {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)
        Text(label)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text("\(Int(grams.rounded()))g")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(color.opacity(0.15))
          Capsule()
            .fill(color)
            .frame(width: geo.size.width * pctOfDaily)
            .animation(reduceMotion ? nil : AppMotion.counterReveal, value: pctOfDaily)
        }
      }
      .frame(height: 4)
    }
  }
}

struct CookingCelebrationPhotoSection: View {
  @Binding var capturedImage: UIImage?
  let cameraPermissionStatus: AppPermissionStatus
  let onOpenCamera: () -> Void
  let onOpenLibrary: () -> Void
  let onOpenSettings: () -> Void
  let appeared: Bool
  let reduceMotion: Bool

  var body: some View {
    Group {
      if let capturedImage {
        FLCard {
          VStack(spacing: AppTheme.Space.sm) {
            Image(uiImage: capturedImage)
              .resizable()
              .scaledToFill()
              .frame(height: 200)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))

            HStack {
              Text("Photo saved")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.positive)

              Spacer()

              Button {
                self.capturedImage = nil
              } label: {
                Text("Retake")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.accent)
              }
            }
          }
        }
      } else {
        Button {
          onOpenCamera()
        } label: {
          HStack(spacing: AppTheme.Space.sm) {
            Image(systemName: "camera.fill")
              .font(.system(size: 18))
              .foregroundStyle(AppTheme.accent)

            VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
              Text("Take a Photo")
                .font(AppTheme.Typography.bodyLarge)
                .foregroundStyle(AppTheme.textPrimary)
              Text("Capture your creation for your cooking journal")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(AppTheme.textSecondary)
          }
          .padding(AppTheme.Space.md)
          .background(
            AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
          )
        }
        .buttonStyle(FLPressableButtonStyle())

        if cameraPermissionStatus == .denied || cameraPermissionStatus == .restricted {
          FLCard(tone: .warning) {
            VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
              Text("Camera permission is off")
                .font(AppTheme.Typography.displayCaption)
                .foregroundStyle(AppTheme.textPrimary)
              Text("Use photo library to continue, or enable camera access in Settings.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)

              HStack(spacing: AppTheme.Space.sm) {
                FLSecondaryButton(
                  "Use Library", systemImage: "photo.on.rectangle", action: onOpenLibrary)
                FLSecondaryButton(
                  "Open Settings", systemImage: "gearshape", action: onOpenSettings)
              }
            }
          }
        }

        if cameraPermissionStatus == .unavailable {
          Text("Camera unavailable on this device. Use the photo library instead.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(reduceMotion ? nil : AppMotion.sectionReveal.delay(0.24), value: appeared)
  }
}
