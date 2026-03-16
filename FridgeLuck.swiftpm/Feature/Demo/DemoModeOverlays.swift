import SwiftUI
import UIKit

struct DemoScenarioPreviewOverlay: View {
  let scenario: DemoScenario
  let demoImage: UIImage?
  let isFirstVisit: Bool
  let onScan: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.72)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        ZStack {
          if let image = demoImage {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .overlay {
                ZStack {
                  Color.black.opacity(0.06)
                  RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.25)],
                    center: .center,
                    startRadius: 80,
                    endRadius: 320
                  )
                }
              }
          } else {
            Color.clear
              .background(
                LinearGradient(
                  colors: scenario.gradientColors,
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .overlay {
                Image(systemName: scenario.icon)
                  .font(.system(size: 48, weight: .semibold))
                  .foregroundStyle(.white.opacity(0.6))
              }
          }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
        .padding(.horizontal, AppTheme.Space.page)

        VStack(spacing: AppTheme.Space.sm) {
          Text(scenario.title)
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)

          Text(scenario.description)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Space.page)

        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(scenario.ingredientNames, id: \.self) { name in
            Text(name)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs + 1)
              .background(.white.opacity(0.12), in: Capsule())
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        Button(action: onScan) {
          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: "viewfinder")
              .font(.system(size: 16, weight: .semibold))
            Text("Scan This Fridge")
              .font(.system(size: 16, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, AppTheme.Space.lg)
          .padding(.vertical, AppTheme.Space.md)
          .background(scenario.accentColor, in: Capsule())
          .shadow(color: scenario.accentColor.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.top, AppTheme.Space.xs)

        if isFirstVisit {
          Text("This is a demo \u{2014} nothing is saved or sent anywhere.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.48))
            .multilineTextAlignment(.center)
        }
      }
    }
    .accessibilityLabel("\(scenario.title) preview")
  }
}

struct DemoScenarioScanningOverlay: View {
  let scenario: DemoScenario
  let demoImage: UIImage?
  let reduceMotion: Bool
  let isFirstVisit: Bool
  let discoveredCount: Int
  let scanComplete: Bool
  @Binding var scannerBracketsVisible: Bool

  var body: some View {
    ZStack {
      Color.black.opacity(0.72)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        ZStack {
          if let image = demoImage {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .overlay {
                ZStack {
                  Color.black.opacity(0.08)
                  RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.30)],
                    center: .center,
                    startRadius: 80,
                    endRadius: 320
                  )
                }
              }
          } else {
            Color.clear
              .background(
                LinearGradient(
                  colors: scenario.gradientColors,
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .overlay {
                Image(systemName: scenario.icon)
                  .font(.system(size: 36, weight: .semibold))
                  .foregroundStyle(.white.opacity(0.6))
              }
          }

          ScanSweepOverlay(isAnimating: !reduceMotion)
          scannerCornerBrackets(accentColor: scenario.accentColor)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
            .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
        .padding(.horizontal, AppTheme.Space.page)

        scanProgressBar()
          .padding(.horizontal, AppTheme.Space.page + AppTheme.Space.md)

        VStack(spacing: AppTheme.Space.sm) {
          Text(scanComplete ? "Analysis complete!" : "Scanning your fridge")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())

          Text(scanStatusText())
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())
        }
        .padding(.horizontal, AppTheme.Space.page)

        if discoveredCount > 0 {
          discoveredIngredientChips()
            .padding(.horizontal, AppTheme.Space.page)
        }
      }
    }
    .onAppear {
      if !reduceMotion {
        withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
          scannerBracketsVisible = true
        }
      } else {
        scannerBracketsVisible = true
      }
    }
    .onDisappear {
      scannerBracketsVisible = false
    }
    .accessibilityLabel("Scanning \(scenario.title) ingredients")
  }

  private func scannerCornerBrackets(accentColor: Color) -> some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let cornerLen: CGFloat = 26
      let inset: CGFloat = 14

      Path { p in
        p.move(to: CGPoint(x: inset, y: inset + cornerLen))
        p.addLine(to: CGPoint(x: inset, y: inset))
        p.addLine(to: CGPoint(x: inset + cornerLen, y: inset))

        p.move(to: CGPoint(x: w - inset - cornerLen, y: inset))
        p.addLine(to: CGPoint(x: w - inset, y: inset))
        p.addLine(to: CGPoint(x: w - inset, y: inset + cornerLen))

        p.move(to: CGPoint(x: w - inset, y: h - inset - cornerLen))
        p.addLine(to: CGPoint(x: w - inset, y: h - inset))
        p.addLine(to: CGPoint(x: w - inset - cornerLen, y: h - inset))

        p.move(to: CGPoint(x: inset + cornerLen, y: h - inset))
        p.addLine(to: CGPoint(x: inset, y: h - inset))
        p.addLine(to: CGPoint(x: inset, y: h - inset - cornerLen))
      }
      .stroke(
        .white.opacity(0.72),
        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
      )
      .shadow(color: accentColor.opacity(0.45), radius: 6, x: 0, y: 0)
    }
    .opacity(scannerBracketsVisible ? 1 : 0)
    .scaleEffect(scannerBracketsVisible ? 1 : 1.06)
  }

  private func scanProgressBar() -> some View {
    let total = max(1, scenario.ingredientNames.count)
    let progress = CGFloat(discoveredCount) / CGFloat(total)

    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.white.opacity(0.10))

        Capsule()
          .fill(
            LinearGradient(
              colors: [scenario.accentColor.opacity(0.9), scenario.accentColor.opacity(0.6)],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: max(4, geo.size.width * progress))
          .shadow(color: scenario.accentColor.opacity(0.4), radius: 4, x: 0, y: 0)
      }
    }
    .frame(height: 3)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: discoveredCount)
  }

  private func discoveredIngredientChips() -> some View {
    FlowLayout(spacing: AppTheme.Space.xxs) {
      ForEach(
        Array(scenario.ingredientNames.prefix(discoveredCount).enumerated()),
        id: \.element
      ) { _, name in
        HStack(spacing: 4) {
          Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))
          Text(name)
            .font(AppTheme.Typography.labelSmall)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, AppTheme.Space.xs)
        .padding(.vertical, AppTheme.Space.xxxs + 1)
        .background(.white.opacity(0.12), in: Capsule())
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.5).combined(with: .opacity),
            removal: .opacity
          )
        )
      }
    }
  }

  private func scanStatusText() -> String {
    if scanComplete {
      let prefix = isFirstVisit ? "All done! " : ""
      return
        "\(prefix)Found \(scenario.ingredientNames.count) ingredients. Preparing review\u{2026}"
    }
    if discoveredCount > 0 {
      return "Found \(discoveredCount) ingredient\(discoveredCount == 1 ? "" : "s") so far\u{2026}"
    }
    if isFirstVisit {
      return "Identifying what\u{2019}s in the fridge\u{2026}"
    }
    return "Finding ingredients in \(scenario.title)\u{2026}"
  }
}
