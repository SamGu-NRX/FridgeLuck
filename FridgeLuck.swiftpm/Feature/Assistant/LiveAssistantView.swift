import FLFeatureLogic
import SwiftUI

struct LiveAssistantView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let recipeContext: LiveAssistantRecipeContext
  let onCompleteLesson: () -> Void
  let onSkipLesson: () -> Void

  @StateObject private var viewModel: LiveAssistantViewModel
  @State private var panelDetent: LiveAssistantPanelDetent = .peek
  @GestureState private var panelDragOffset: CGFloat = 0
  @State private var showComposer = false

  init(
    recipeContext: LiveAssistantRecipeContext,
    onCompleteLesson: @escaping () -> Void,
    onSkipLesson: @escaping () -> Void
  ) {
    self.recipeContext = recipeContext
    self.onCompleteLesson = onCompleteLesson
    self.onSkipLesson = onSkipLesson
    _viewModel = StateObject(wrappedValue: LiveAssistantViewModel(recipeContext: recipeContext))
  }

  var body: some View {
    GeometryReader { geo in
      let panelHeight = LiveAssistantPanelLayout.clampedHeight(
        for: panelDetent,
        translation: panelDragOffset,
        screenHeight: geo.size.height
      )

      ZStack(alignment: .bottom) {
        cameraLayer

        focusGuide(in: geo.size)
          .allowsHitTesting(false)

        topChrome

        statusShell(panelHeight: panelHeight)

        lowerChrome(panelHeight: panelHeight, geo: geo)
      }
      .ignoresSafeArea()
    }
    .navigationBarHidden(true)
    .task {
      await viewModel.start()
    }
    .onDisappear {
      viewModel.stop()
    }
  }

  private var cameraLayer: some View {
    ZStack {
      LiveAssistantPreviewView(session: viewModel.captureCoordinator.captureSession)
        .ignoresSafeArea()

      LinearGradient(
        colors: [
          Color.black.opacity(0.42),
          Color.black.opacity(0.04),
          Color.black.opacity(0.55),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)
    }
  }

  private var topChrome: some View {
    VStack(spacing: 0) {
      HStack(spacing: AppTheme.Space.sm) {
        Button {
          onSkipLesson()
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
        }

        VStack(spacing: 2) {
          Text(recipeContext.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)

          Text(stepCounterLabel)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)

        connectionStatusPill
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xxl + 6)

      Spacer()
    }
    .overlay(alignment: .top) {
      LinearGradient(
        colors: [Color.black.opacity(0.55), Color.clear],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 150)
      .allowsHitTesting(false)
    }
  }

  private var stepCounterLabel: String {
    "\(viewModel.currentStepIndex + 1)/\(max(viewModel.totalSteps, 1))"
  }

  private var connectionStatusPill: some View {
    let label: String
    let tint: Color

    switch viewModel.connectionState {
    case .connected:
      label = "Live"
      tint = AppTheme.sage
    case .connecting:
      label = "Connecting"
      tint = AppTheme.oat
    case .failed:
      label = "Issue"
      tint = AppTheme.accent
    case .disconnected:
      label = "Closed"
      tint = AppTheme.dustyRose
    case .idle:
      label = "Starting"
      tint = AppTheme.oat
    }

    return HStack(spacing: AppTheme.Space.xxs) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)

      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(.white.opacity(0.88))
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
    .animation(reduceMotion ? nil : AppMotion.colorTransition, value: label)
  }

  private func focusGuide(in size: CGSize) -> some View {
    VStack(spacing: AppTheme.Space.sm) {
      LiveAssistantFocusFrame()
        .frame(
          width: min(size.width * 0.68, 316),
          height: min(size.height * 0.31, 250)
        )

      Text("Keep your board, ingredients, and pan inside the frame.")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.chipVertical)
        .background(.black.opacity(0.22), in: Capsule())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 180)
  }

  @ViewBuilder
  private func statusShell(panelHeight: CGFloat) -> some View {
    if let card = viewModel.statusCard {
      VStack {
        Spacer()

        LiveAssistantStatusCard(
          card: card,
          retryAction: {
            Task { await viewModel.reconnect() }
          }
        )
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, panelHeight + 108)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.96)))
      .animation(reduceMotion ? nil : AppMotion.bubbleAppear, value: card)
    }
  }

  private func lowerChrome(panelHeight: CGFloat, geo: GeometryProxy) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      if viewModel.statusCard == nil, viewModel.showBubble, !viewModel.bubbleText.isEmpty {
        floatingBubble
          .padding(.horizontal, AppTheme.Space.page)
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .move(edge: .bottom)),
              removal: .opacity
            )
          )
      }

      controlDock
        .padding(.horizontal, AppTheme.Space.page)

      bottomPanel(panelHeight: panelHeight, geo: geo)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .animation(reduceMotion ? nil : AppMotion.bubbleAppear, value: viewModel.showBubble)
  }

  private var floatingBubble: some View {
    HStack(alignment: .top, spacing: AppTheme.Space.xs) {
      Image(systemName: "waveform")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(AppTheme.accentLight)

      Text(viewModel.bubbleText)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    )
    .allowsHitTesting(false)
  }

  private var controlDock: some View {
    HStack(spacing: AppTheme.Space.lg) {
      controlButton(
        icon: "camera.rotate",
        label: "Retry",
        isActive: false,
        isEnabled: true
      ) {
        Task { await viewModel.reconnect() }
      }

      controlButton(
        icon: viewModel.isListening ? "mic.fill" : "mic.slash.fill",
        label: viewModel.isListening ? "Listening" : "Mic",
        isActive: viewModel.isListening,
        isEnabled: viewModel.canUseMicrophone
      ) {
        Task { await viewModel.toggleListening() }
      }

      controlButton(
        icon: "text.bubble",
        label: "Transcript",
        isActive: showComposer,
        isEnabled: viewModel.canUseComposer
      ) {
        withAnimation(reduceMotion ? nil : AppMotion.panelSnap) {
          showComposer.toggle()
          panelDetent = showComposer ? .full : .step
        }
      }

      controlButton(
        icon: "xmark",
        label: "End",
        isActive: false,
        isEnabled: true
      ) {
        onSkipLesson()
        dismiss()
      }
    }
  }

  private func controlButton(
    icon: String,
    label: String,
    isActive: Bool,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: AppTheme.Space.xxs) {
        ZStack {
          if isActive {
            Circle()
              .fill(AppTheme.accent.opacity(0.30))
              .frame(width: 64, height: 64)
              .scaleEffect(1.08)
              .opacity(0.75)
              .animation(
                reduceMotion ? nil : AppMotion.micPulse.repeatForever(autoreverses: true),
                value: isActive
              )
          }

          Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.45))
            .frame(width: 56, height: 56)
            .background(
              (isActive ? AppTheme.accent : Color.black.opacity(0.34)),
              in: Circle()
            )
            .overlay(
              Circle()
                .stroke(.white.opacity(isEnabled ? 0.10 : 0.04), lineWidth: 1)
            )
        }

        Text(label)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(.white.opacity(isEnabled ? 0.74 : 0.36))
      }
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(!isEnabled)
  }

  private func bottomPanel(panelHeight: CGFloat, geo: GeometryProxy) -> some View {
    VStack(spacing: 0) {
      dragHandle

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          stepSection

          if panelDetent != .peek {
            stepNavigation
          }

          if panelDetent == .full {
            transcriptSection
            composerSection
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.bottom, AppTheme.Space.xxl)
      }
      .scrollDisabled(panelDetent == .peek)
    }
    .frame(height: panelHeight)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(AppTheme.deepOlive.opacity(0.98))
        .overlay(
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .stroke(AppTheme.slabStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 28, x: 0, y: -8)
    )
    .gesture(
      DragGesture(minimumDistance: 6)
        .updating($panelDragOffset) { value, state, _ in
          state = value.translation.height
        }
        .onEnded { value in
          withAnimation(reduceMotion ? nil : AppMotion.panelSnap) {
            panelDetent = LiveAssistantPanelLayout.resolvedDetent(
              from: panelDetent,
              translation: value.translation.height,
              predictedEndTranslation: value.predictedEndTranslation.height,
              screenHeight: geo.size.height
            )
          }
        }
    )
  }

  private var dragHandle: some View {
    VStack(spacing: AppTheme.Space.sm) {
      Capsule()
        .fill(.white.opacity(0.22))
        .frame(width: 42, height: 5)
        .padding(.top, AppTheme.Space.sm)

      HStack(spacing: AppTheme.Space.sm) {
        Text("Step \(viewModel.currentStepIndex + 1)")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.accentLight)

        Text("of \(max(viewModel.totalSteps, 1))")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(.white.opacity(0.56))

        Spacer()

        if panelDetent == .peek {
          Text("Swipe up for guidance")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.56))
        } else {
          Text(recipeContext.title)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.xs)
      .contentShape(Rectangle())
      .onTapGesture {
        withAnimation(reduceMotion ? nil : AppMotion.panelSnap) {
          panelDetent = panelDetent == .peek ? .step : .peek
        }
      }
    }
  }

  private var stepSection: some View {
    let steps = viewModel.instructionSteps
    let index = viewModel.currentStepIndex
    let isComplete = viewModel.completedSteps.contains(index)

    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .firstTextBaseline) {
        Text(String(format: "%02d", index + 1))
          .font(.system(size: 58, weight: .bold, design: .serif))
          .foregroundStyle(.white.opacity(0.12))

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Current step")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.accentLight)
            .textCase(.uppercase)
            .kerning(1.0)

          Text("\(index + 1) of \(max(viewModel.totalSteps, 1))")
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white.opacity(0.82))
        }

        Spacer()
      }

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(.white.opacity(0.10))

          Capsule()
            .fill(
              LinearGradient(
                colors: [AppTheme.accent, AppTheme.accentLight],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: geo.size.width * viewModel.stepProgress)
            .animation(reduceMotion ? nil : AppMotion.progressBar, value: viewModel.stepProgress)
        }
      }
      .frame(height: 5)

      if index >= 0, index < steps.count {
        Text(steps[index])
          .font(.system(.title3, design: .rounded, weight: .regular))
          .foregroundStyle(.white.opacity(0.96))
          .lineSpacing(6)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Button {
        withAnimation(reduceMotion ? nil : AppMotion.chipToggle) {
          viewModel.toggleStepComplete()
        }
      } label: {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(isComplete ? AppTheme.sageLight : .white.opacity(0.58))

          Text(isComplete ? "Step complete" : "Mark as done")
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(isComplete ? AppTheme.sageLight : .white.opacity(0.74))
        }
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.vertical, AppTheme.Space.sm)
        .background(
          isComplete ? AppTheme.sage.opacity(0.22) : .white.opacity(0.06),
          in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
            .stroke(isComplete ? AppTheme.sage.opacity(0.28) : .white.opacity(0.08), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
    }
  }

  private var stepNavigation: some View {
    HStack(spacing: AppTheme.Space.md) {
      if viewModel.currentStepIndex > 0 {
        FLSecondaryButton("Back", systemImage: "chevron.left") {
          withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
            viewModel.goToPreviousStep()
          }
        }
      }

      if viewModel.isOnLastStep {
        FLPrimaryButton("Finish Cook", systemImage: "checkmark.circle") {
          onCompleteLesson()
          dismiss()
        }
      } else {
        FLPrimaryButton("Next Step", systemImage: "chevron.right") {
          withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
            viewModel.goToNextStep()
          }
        }
      }
    }
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLWaveDivider()

      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "text.bubble")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppTheme.accentLight)

        Text("Transcript")
          .font(AppTheme.Typography.label)
          .foregroundStyle(.white.opacity(0.84))
      }

      if viewModel.transcript.isEmpty {
        Text("Le Chef's live guidance will appear here.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(.white.opacity(0.56))
      } else {
        VStack(spacing: AppTheme.Space.xs) {
          ForEach(viewModel.transcript.suffix(8)) { entry in
            transcriptBubble(entry)
          }
        }
      }
    }
  }

  private func transcriptBubble(_ entry: LiveAssistantTranscriptEntry) -> some View {
    let isAssistant = entry.role == .assistant
    let isUser = entry.role == .user

    return HStack {
      if isAssistant { Spacer(minLength: 40) }

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(isAssistant ? "Le Chef" : isUser ? "You" : "System")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(.white.opacity(0.48))

        Text(entry.text)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(.white.opacity(0.88))
      }
      .padding(AppTheme.Space.sm)
      .background(
        isAssistant
          ? AppTheme.accent.opacity(0.18)
          : isUser
            ? AppTheme.sage.opacity(0.18)
            : .white.opacity(0.07),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(.white.opacity(0.06), lineWidth: 1)
      )

      if !isAssistant { Spacer(minLength: 40) }
    }
  }

  private var composerSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLWaveDivider()

      Text("Ask Le Chef")
        .font(AppTheme.Typography.label)
        .foregroundStyle(.white.opacity(0.84))

      HStack(spacing: AppTheme.Space.sm) {
        TextField("Type a quick question…", text: $viewModel.composerText, axis: .vertical)
          .font(AppTheme.Typography.bodyMedium)
          .lineLimit(1...3)
          .padding(.horizontal, AppTheme.Space.md)
          .padding(.vertical, AppTheme.Space.sm)
          .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
              .stroke(.white.opacity(0.08), lineWidth: 1)
          )
          .foregroundStyle(.white.opacity(0.9))

        Button {
          Task { await viewModel.sendComposerText() }
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(
              viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .white.opacity(0.24) : AppTheme.accentLight
            )
        }
        .disabled(
          !viewModel.canUseComposer
            || viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
  }
}

private struct LiveAssistantFocusFrame: View {
  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = geo.size.height
      let segment = min(width, height) * 0.18

      ZStack {
        frameCorner(x: 0, y: 0, segment: segment)
        frameCorner(x: width, y: 0, segment: segment, isTrailing: true)
        frameCorner(x: 0, y: height, segment: segment, isBottom: true)
        frameCorner(x: width, y: height, segment: segment, isTrailing: true, isBottom: true)
      }
    }
  }

  private func frameCorner(
    x: CGFloat,
    y: CGFloat,
    segment: CGFloat,
    isTrailing: Bool = false,
    isBottom: Bool = false
  ) -> some View {
    Path { path in
      let horizontalStart = CGPoint(x: x + (isTrailing ? -segment : 0), y: y)
      let horizontalEnd = CGPoint(x: x + (isTrailing ? 0 : segment), y: y)
      let verticalStart = CGPoint(x: x, y: y + (isBottom ? -segment : 0))
      let verticalEnd = CGPoint(x: x, y: y + (isBottom ? 0 : segment))

      path.move(to: horizontalStart)
      path.addLine(to: horizontalEnd)
      path.move(to: verticalStart)
      path.addLine(to: verticalEnd)
    }
    .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 3, lineCap: .round))
  }
}

private struct LiveAssistantStatusCard: View {
  let card: LiveAssistantViewModel.StatusCardModel
  let retryAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text(card.eyebrow)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.accentLight)
        .textCase(.uppercase)
        .kerning(0.9)

      Text(card.title)
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(.white)

      Text(card.message)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(.white.opacity(0.76))

      if card.showsRetry {
        FLPrimaryButton("Retry Connection", systemImage: "arrow.clockwise") {
          retryAction()
        }
      }
    }
    .padding(AppTheme.Space.lg)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    )
  }
}
