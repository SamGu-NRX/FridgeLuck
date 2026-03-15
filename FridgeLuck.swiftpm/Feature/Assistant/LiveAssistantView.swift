import SwiftUI

struct LiveAssistantView: View {
  @Environment(\.dismiss) private var dismiss

  let recipeContext: LiveAssistantRecipeContext
  let onCompleteLesson: () -> Void
  let onSkipLesson: () -> Void

  @StateObject private var viewModel: LiveAssistantViewModel

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
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        previewCard
        recipeCard
        transcriptCard
        composerCard
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.bottomClearance)
    }
    .navigationTitle("Live Kitchen Guide")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Skip") {
          onSkipLesson()
          dismiss()
        }
      }
    }
    .task {
      await viewModel.start()
    }
    .onDisappear {
      viewModel.stop()
    }
  }

  private var previewCard: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          FLSectionHeader(
            "Live View",
            subtitle: "Place the phone on a counter stand near your prep area.",
            icon: "video.badge.waveform"
          )
          Spacer()
          FLStatusPill(text: connectionLabel, kind: connectionKind)
        }

        ZStack(alignment: .bottomLeading) {
          LiveAssistantPreviewView(session: viewModel.captureCoordinator.captureSession)
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))

          LinearGradient(
            colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
          )
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))

          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text("Counter stand recommended")
              .font(AppTheme.Typography.label)
              .foregroundStyle(.white)
            Text("Keep the cutting board and pan in frame so Gemini can track your progress.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(.white.opacity(0.82))
          }
          .padding(AppTheme.Space.md)
        }

        HStack(spacing: AppTheme.Space.xs) {
          permissionPill("Camera", status: viewModel.cameraPermissionStatus)
          permissionPill("Mic", status: viewModel.microphonePermissionStatus)
          if viewModel.isListening {
            FLStatusPill(text: "Listening", kind: .positive)
          }
        }
      }
    }
  }

  private var recipeCard: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          recipeContext.title,
          subtitle: "\(recipeContext.timeMinutes) min · \(recipeContext.servings) servings",
          icon: "fork.knife"
        )

        Text(recipeContext.instructions)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(4)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.xs) {
            FLStatusPill(text: "Recipe grounded", kind: .positive)
            FLStatusPill(text: "\(recipeContext.ingredients.count) ingredients", kind: .neutral)
            FLStatusPill(text: "Safety via Google", kind: .neutral)
          }
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.xs) {
            ForEach(recipeContext.ingredients.prefix(8)) { ingredient in
              Text(ingredient.quantityText.map { "\(ingredient.name) · \($0)" } ?? ingredient.name)
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, AppTheme.Space.sm)
                .padding(.vertical, AppTheme.Space.chipVertical)
                .background(AppTheme.surfaceMuted, in: Capsule())
            }
          }
        }
      }
    }
  }

  private var transcriptCard: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Transcript",
          subtitle: "Live guidance stays grounded to your recipe and camera view.",
          icon: "text.bubble"
        )

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          ForEach(viewModel.transcript) { entry in
            HStack {
              if entry.role == .assistant { Spacer(minLength: 24) }
              VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
                Text(
                  entry.role == .assistant ? "Gemini Live" : entry.role == .user ? "You" : "System"
                )
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
                Text(entry.text)
                  .font(AppTheme.Typography.bodySmall)
                  .foregroundStyle(AppTheme.textPrimary)
              }
              .padding(AppTheme.Space.sm)
              .background(
                entry.role == .assistant
                  ? AppTheme.surfaceMuted
                  : entry.role == .user ? AppTheme.accentMuted : AppTheme.oat.opacity(0.14),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              )
              if entry.role != .assistant { Spacer(minLength: 24) }
            }
          }
        }
      }
    }
  }

  private var composerCard: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        TextField(
          "Ask about the next step, substitutions, or safety checks…",
          text: $viewModel.composerText, axis: .vertical
        )
        .textFieldStyle(.roundedBorder)

        if let supportMessage = supportMessage {
          Text(supportMessage)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        HStack(spacing: AppTheme.Space.sm) {
          FLSecondaryButton(
            viewModel.isListening ? "Stop Mic" : "Start Mic",
            systemImage: viewModel.isListening ? "stop.circle.fill" : "mic.fill"
          ) {
            Task { await viewModel.toggleListening() }
          }

          FLPrimaryButton("Send", systemImage: "arrow.up.circle.fill") {
            Task { await viewModel.sendComposerText() }
          }
        }

        if case .failed = viewModel.connectionState {
          FLSecondaryButton("Retry Connection", systemImage: "arrow.clockwise") {
            Task { await viewModel.reconnect() }
          }
        }

        FLSecondaryButton("Lesson Complete", systemImage: "checkmark.circle") {
          onCompleteLesson()
          dismiss()
        }
      }
    }
  }

  private var connectionLabel: String {
    switch viewModel.connectionState {
    case .idle: return "Idle"
    case .connecting: return "Connecting"
    case .connected: return "Live"
    case .disconnected: return "Closed"
    case .failed: return "Error"
    }
  }

  private var connectionKind: FLStatusPill.Kind {
    switch viewModel.connectionState {
    case .connected:
      return .positive
    case .failed:
      return .warning
    default:
      return .neutral
    }
  }

  private func permissionPill(_ label: String, status: AppPermissionStatus) -> some View {
    let kind: FLStatusPill.Kind = status.isAuthorizedLike ? .positive : .warning
    return FLStatusPill(text: "\(label) \(status.isAuthorizedLike ? "Ready" : "Off")", kind: kind)
  }

  private var supportMessage: String? {
    if !viewModel.cameraPermissionStatus.isAuthorizedLike
      || !viewModel.microphonePermissionStatus.isAuthorizedLike
    {
      return
        "Grant camera and microphone access so the live guide can watch your prep area and hear your questions."
    }

    switch viewModel.connectionState {
    case .failed(let message):
      return message
    case .disconnected:
      return "The live session closed. Retry when your Cloud Run bridge is reachable."
    default:
      return nil
    }
  }
}

extension AppPermissionStatus {
  fileprivate var isAuthorizedLike: Bool {
    self == .authorized || self == .limited
  }
}
