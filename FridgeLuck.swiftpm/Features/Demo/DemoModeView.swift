import SwiftUI

/// Unified demo hub — users pick a fridge scenario or use their own photo.
/// Replaces the old `DemoScenarioPicker` embedded in the tutorial home
/// with a dedicated, full-page experience.
struct DemoModeView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - State

  @State private var appeared = false
  @State private var loadingScenario: DemoScenario?
  @State private var loadedDetections: [Detection] = []
  @State private var loadedProvenance: ScanProvenance = .bundledFixture
  @State private var navigateToReview = false
  @State private var navigateToScan = false
  @State private var demoImage: UIImage?
  @State private var scanProgress: CGFloat = 0
  @State private var discoveredCount: Int = 0
  @State private var scannerBracketsVisible = false

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

          scenarioGrid
            .padding(.horizontal, AppTheme.Space.page)

          ownPhotoCard
            .padding(.horizontal, AppTheme.Space.page)
        }
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.bottomClearance)
      }

      // Loading overlay
      if let scenario = loadingScenario {
        scenarioLoadingOverlay(scenario)
          .transition(.opacity)
      }
    }
    .navigationTitle("Demo Mode")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .navigationDestination(isPresented: $navigateToReview) {
      IngredientReviewView(
        detections: loadedDetections,
        scanProvenance: loadedProvenance
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
      selectScenario(scenario)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        // Icon
        Image(systemName: scenario.icon)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 44, height: 44)
          .background(Circle().fill(.white.opacity(0.15)))

        // Title & description
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

        // Ingredient chips
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

        // Recipe hint
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
    .disabled(loadingScenario != nil)
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
    .disabled(loadingScenario != nil)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(
      reduceMotion ? nil : AppMotion.gentle.delay(0.28),
      value: appeared
    )
  }

  // MARK: - Scanning Overlay

  private func scenarioLoadingOverlay(_ scenario: DemoScenario) -> some View {
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
          Text("Scanning your fridge")
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)

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
    if discoveredCount > 0 {
      return "Found \(discoveredCount) ingredient\(discoveredCount == 1 ? "" : "s") so far\u{2026}"
    }
    return "Finding ingredients in \(scenario.title)\u{2026}"
  }

  // MARK: - Actions

  private func selectScenario(_ scenario: DemoScenario) {
    guard loadingScenario == nil else { return }

    // Pre-load the scenario-specific photo for the scan overlay
    demoImage = DemoScanService.loadScenarioImage(for: scenario)
    discoveredCount = 0
    scannerBracketsVisible = false

    withAnimation(reduceMotion ? nil : AppMotion.standard) {
      loadingScenario = scenario
    }

    Task {
      // Start the scan in the background
      async let payloadFetch = DemoScanService.loadDemoPayload(
        scenario: scenario,
        using: deps.visionService
      )

      // Animate ingredient discovery count while loading
      let totalIngredients = scenario.ingredientNames.count
      for i in 1...totalIngredients {
        try? await Task.sleep(for: .milliseconds(Int.random(in: 180...350)))
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
          discoveredCount = i
        }
      }

      let payload = await payloadFetch

      loadedDetections = payload.detections
      loadedProvenance = payload.provenance

      // Ensure minimum visible scanning time for polish (at least 1.8s total)
      try? await Task.sleep(for: .milliseconds(400))

      withAnimation(reduceMotion ? nil : AppMotion.standard) {
        loadingScenario = nil
      }

      // Small delay for overlay dismiss animation
      try? await Task.sleep(for: .milliseconds(150))
      navigateToReview = true
    }
  }
}
