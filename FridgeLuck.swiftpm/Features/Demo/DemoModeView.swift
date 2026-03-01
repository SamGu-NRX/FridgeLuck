import SwiftUI

/// Unified demo hub — users pick a fridge scenario or use their own photo.
/// Replaces the old `DemoScenarioPicker` embedded in the tutorial home
/// with a dedicated, full-page experience.
struct DemoModeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - State

  @State private var appeared = false
  @State private var overlayPhase: OverlayPhase = .hidden
  @State private var activeScenario: DemoScenario?
  @State private var loadedDetections: [Detection] = []
  @State private var loadedProvenance: ScanProvenance = .bundledFixture
  @State private var navigateToReview = false
  @State private var navigateToScan = false
  @State private var demoImage: UIImage?
  @State private var scanProgress: CGFloat = 0
  @State private var discoveredCount: Int = 0
  @State private var scannerBracketsVisible = false
  @State private var scanComplete = false
  @State private var scanTask: Task<Void, Never>?

  /// The overlay phases: preview first, then scanning.
  private enum OverlayPhase: Equatable {
    case hidden
    case preview(DemoScenario)
    case scanning(DemoScenario)
  }

  private var isOverlayVisible: Bool {
    overlayPhase != .hidden
  }

  // MARK: - Layout

  private let columns = [
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
  ]

  // MARK: - Body

  var body: some View {
    ZStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
          header
            .padding(.horizontal, AppTheme.Space.page)

          howItWorksCallout
            .padding(.horizontal, AppTheme.Space.page)

          scenarioGrid
            .padding(.horizontal, AppTheme.Space.page)

          ownPhotoCard
            .padding(.horizontal, AppTheme.Space.page)
        }
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }

      if isOverlayVisible, let scenario = activeScenario {
        overlayContent(scenario)
          .transition(.opacity)
      }
    }
    .navigationTitle("Demo Mode")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .flPageBackground()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: handleBackButton) {
          Image(systemName: "chevron.left")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(width: 44, height: 44)
            .background(
              AppTheme.surface.opacity(0.98),
              in: Circle()
            )
            .overlay(
              Circle()
                .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOverlayVisible ? "Close preview" : "Back")
      }
    }
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: loadedDetections,
        scanProvenance: loadedProvenance,
        fridgeImage: demoImage
      )
    }
    .navigationDestination(isPresented: $navigateToScan) {
      ScanView(mode: .live)
    }
    .onAppear {
      guard !reduceMotion, !appeared else {
        appeared = true
        return
      }
      withAnimation(AppMotion.heroAppear.delay(0.1)) {
        appeared = true
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text("Try FridgeLuck")
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)

      Text("Pick a pre-stocked fridge to explore, or snap your own photo.")
        .font(AppTheme.Typography.bodyLarge)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
  }

  // MARK: - How It Works Callout

  private var howItWorksCallout: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "lightbulb.min.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(AppTheme.oat)
        .frame(width: 32, height: 32)
        .background(AppTheme.oat.opacity(0.15), in: Circle())

      Text(
        "Each card is a realistic fridge scenario with different ingredients. Tap one to see how FridgeLuck scans and identifies what\u{2019}s inside."
      )
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.oat.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.20), lineWidth: 1)
    )
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.05),
      value: appeared
    )
  }

  // MARK: - Scenario Grid

  private var scenarioGrid: some View {
    LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
      ForEach(Array(DemoScenario.allCases.enumerated()), id: \.element.id) { index, scenario in
        scenarioCard(scenario, index: index)
      }
    }
  }

  private func scenarioCard(_ scenario: DemoScenario, index: Int) -> some View {
    Button {
      beginPreview(scenario)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Image(systemName: scenario.icon)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 44, height: 44)
          .background(Circle().fill(.white.opacity(0.15)))

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(scenario.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(scenario.description)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }

        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(scenario.ingredientNames.prefix(4), id: \.self) { name in
            Text(name)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.12), in: Capsule())
          }
          if scenario.ingredientNames.count > 4 {
            Text("+\(scenario.ingredientNames.count - 4)")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.6))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.08), in: Capsule())
          }
        }

        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "fork.knife")
            .font(.system(size: 10, weight: .medium))
          Text(scenario.recipeHint)
            .font(AppTheme.Typography.labelSmall)
        }
        .foregroundStyle(.white.opacity(0.58))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .background(
        LinearGradient(
          colors: scenario.gradientColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(.white.opacity(0.05))
          .frame(width: 60, height: 60)
          .blur(radius: 15)
          .offset(x: 15, y: -10)
          .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .shadow(color: scenario.accentColor.opacity(0.15), radius: 8, x: 0, y: 4)
      .rotationEffect(.degrees(scenario.cardRotation), anchor: .center)
    }
    .buttonStyle(.plain)
    .disabled(isOverlayVisible)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(
      reduceMotion
        ? nil : AppMotion.cardSpring.delay(Double(index) * AppMotion.staggerDelay + 0.08),
      value: appeared
    )
  }

  // MARK: - Own Photo Card

  private var ownPhotoCard: some View {
    Button {
      navigateToScan = true
    } label: {
      HStack(spacing: AppTheme.Space.md) {
        Image(systemName: "camera.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .frame(width: 48, height: 48)
          .background(AppTheme.accentMuted, in: Circle())

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Use Your Own Photo")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Snap a photo of your real fridge or pantry.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(AppTheme.Space.md)
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .strokeBorder(
            AppTheme.oat.opacity(0.40),
            style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
          )
      )
    }
    .buttonStyle(.plain)
    .disabled(isOverlayVisible)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.28),
      value: appeared
    )
  }

  // MARK: - Overlay Content (Preview → Scanning)

  @ViewBuilder
  private func overlayContent(_ scenario: DemoScenario) -> some View {
    switch overlayPhase {
    case .preview:
      scenarioPreviewOverlay(scenario)
    case .scanning:
      scenarioScanningOverlay(scenario)
    case .hidden:
      EmptyView()
    }
  }

  // MARK: - Scenario Preview Overlay

  private func scenarioPreviewOverlay(_ scenario: DemoScenario) -> some View {
    ZStack {
      Color.black.opacity(0.72)
        .ignoresSafeArea()

      VStack(spacing: AppTheme.Space.lg) {
        // Fridge image preview
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

        // Ingredient preview pills
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

        Button {
          beginScanning(scenario)
        } label: {
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
      }
    }
    .accessibilityLabel("\(scenario.title) preview")
  }

  // MARK: - Scanning Overlay

  private func scenarioScanningOverlay(_ scenario: DemoScenario) -> some View {
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

        scanProgressBar(scenario)
          .padding(.horizontal, AppTheme.Space.page + AppTheme.Space.md)

        VStack(spacing: AppTheme.Space.sm) {
          Text(scanComplete ? "Analysis complete!" : "Scanning your fridge")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())

          Text(scanStatusText(scenario))
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())
        }
        .padding(.horizontal, AppTheme.Space.page)

        if discoveredCount > 0 {
          discoveredIngredientChips(scenario)
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

  // MARK: - Scanner Viewfinder Brackets

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

  // MARK: - Scan Progress Bar

  private func scanProgressBar(_ scenario: DemoScenario) -> some View {
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

  // MARK: - Discovered Ingredient Chips

  private func discoveredIngredientChips(_ scenario: DemoScenario) -> some View {
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

  private func scanStatusText(_ scenario: DemoScenario) -> String {
    if scanComplete {
      return "Found \(scenario.ingredientNames.count) ingredients. Preparing review\u{2026}"
    }
    if discoveredCount > 0 {
      return "Found \(discoveredCount) ingredient\(discoveredCount == 1 ? "" : "s") so far\u{2026}"
    }
    return "Finding ingredients in \(scenario.title)\u{2026}"
  }

  // MARK: - Actions

  /// Phase 1: Show the fridge preview with scenario info.
  private func beginPreview(_ scenario: DemoScenario) {
    guard !isOverlayVisible else { return }
    scanTask?.cancel()
    scanTask = nil

    demoImage = DemoScanService.loadScenarioImage(for: scenario)
    activeScenario = scenario
    discoveredCount = 0
    scanComplete = false
    scannerBracketsVisible = false

    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .preview(scenario)
    }
  }

  /// Phase 2: Transition from preview to scanning with the slower animation.
  private func beginScanning(_ scenario: DemoScenario) {
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .scanning(scenario)
    }

    scanTask?.cancel()
    scanTask = Task {
      async let payloadFetch = DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )

      // Slower ingredient discovery animation (300-500ms per ingredient)
      let totalIngredients = scenario.ingredientNames.count
      for i in 1...totalIngredients {
        do {
          try await Task.sleep(for: .milliseconds(Int.random(in: 300...500)))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          discoveredCount = i
        }
      }

      let payload = await payloadFetch
      guard !Task.isCancelled else { return }

      loadedDetections = payload.detections
      loadedProvenance = payload.provenance

      // Show "Analysis complete!" for a longer beat
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        scanComplete = true
      }
      do {
        try await Task.sleep(for: .milliseconds(800))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }

      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        overlayPhase = .hidden
        activeScenario = nil
      }

      do {
        try await Task.sleep(for: .milliseconds(180))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      navigateToReview = true
      scanTask = nil
    }
  }

  private func handleBackButton() {
    if isOverlayVisible {
      closeOverlay()
      return
    }
    dismiss()
  }

  private func closeOverlay() {
    scanTask?.cancel()
    scanTask = nil
    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      overlayPhase = .hidden
      activeScenario = nil
    }
    discoveredCount = 0
    scanComplete = false
    scannerBracketsVisible = false
  }
}
