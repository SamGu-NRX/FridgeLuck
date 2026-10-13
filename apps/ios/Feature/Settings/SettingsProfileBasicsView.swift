import SwiftUI

/// Renders ProfileBasicsFlow's explicit state machine. All state lives in the flow;
/// the view mirrors phases, forwards field edits, and dismisses only after a
/// persisted save. It never touches the repository directly, so cancel and
/// navigation back during editing write nothing.
struct SettingsProfileBasicsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var deps: AppDependencies

  let onSaved: () -> Void

  @State private var flow: ProfileBasicsFlow?
  @State private var phase: ProfileBasicsPhase = .loading

  var body: some View {
    Group {
      switch phase {
      case .loading:
        loadingView
      case .loadFailed(let message):
        loadFailedView(message: message)
      case .editing, .validating, .saving, .saveFailed, .saved:
        editingForm
      }
    }
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Profile Basics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbarContent }
    .flPageBackground(renderMode: .interactive)
    // Motion: subtle opacity fade on phase swaps only; none under Reduce Motion.
    .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.15), value: phase)
    .task {
      createFlowIfNeeded()
    }
    .onChange(of: phase) { _, newValue in
      if newValue == .saved {
        dismiss()
      }
    }
  }

  // MARK: - Flow wiring

  private func createFlowIfNeeded() {
    guard flow == nil else { return }
    let newFlow = ProfileBasicsFlow(
      fetchProfile: { try deps.userDataRepository.fetchHealthProfile() },
      saveProfile: { try deps.userDataRepository.saveHealthProfile($0) },
      onSaved: {
        AppPreferencesStore.notification(.success)
        onSaved()
      }
    )
    newFlow.onPhaseChange = { phase = $0 }
    flow = newFlow
    newFlow.load()
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      if cancelVisible {
        Button("Cancel", role: .cancel) {
          dismiss()
        }
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      if saveAffordance != .hidden {
        Button(action: saveAction) {
          if showsInProgress {
            ProgressView()
          } else {
            Text("Save")
          }
        }
        .disabled(saveDisabled)
      }
    }
  }

  private enum SaveAffordance: Equatable {
    case hidden
    case ready
    case inProgress
    case retry
  }

  private var saveAffordance: SaveAffordance {
    switch phase {
    case .loading, .loadFailed, .saved:
      return .hidden  // no Save affordance before a draft loads; none after it saves
    case .editing:
      return .ready
    case .validating, .saving:
      return .inProgress  // disabled to prevent double-tap
    case .saveFailed:
      return .retry  // retries the failed save with the retained draft
    }
  }

  private var cancelVisible: Bool {
    switch phase {
    case .validating, .saving, .saved:
      return false  // a committed save is never presented as cancelled
    default:
      return true
    }
  }

  private var saveAction: () -> Void {
    switch phase {
    case .saveFailed:
      return { flow?.retrySave() }
    default:
      return { flow?.save() }
    }
  }

  private var saveDisabled: Bool {
    switch phase {
    case .validating, .saving:
      return true
    default:
      return false
    }
  }

  private var showsInProgress: Bool {
    switch phase {
    case .validating, .saving:
      return true
    default:
      return false
    }
  }

  // MARK: - Draft-backed form

  private var editingForm: some View {
    Form {
      Section {
        TextField("Display name", text: displayNameBinding)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()

        TextField("Age", text: ageBinding)
          .keyboardType(.numberPad)
      } footer: {
        if let message = footerErrorMessage {
          errorFooter(message)
        } else {
          FLSettingsFootnote(
            text: "Name and age personalize your recipe recommendations."
          )
        }
      }
    }
  }

  /// Every phase that renders fields also carries the draft to render them from.
  private var draft: ProfileBasicsDraft? {
    switch phase {
    case .editing(let draft, _):
      return draft
    case .validating(let draft):
      return draft
    case .saving(let draft):
      return draft
    case .saveFailed(let draft, _):
      return draft
    case .loading, .loadFailed, .saved:
      return nil
    }
  }

  private var displayNameBinding: Binding<String> {
    Binding(
      get: { draft?.displayNameText ?? "" },
      set: { flow?.setDisplayNameText($0) }
    )
  }

  private var ageBinding: Binding<String> {
    Binding(
      get: { draft?.ageText ?? "" },
      set: { flow?.setAgeText($0) }
    )
  }

  private var footerErrorMessage: String? {
    switch phase {
    case .editing(_, let validation):
      if case .invalid(let message) = validation {
        return message
      }
      return nil
    case .saveFailed(_, let message):
      return message
    case .loading, .loadFailed, .validating, .saving, .saved:
      return nil
    }
  }

  private func errorFooter(_ message: String) -> some View {
    Text(message)
      .font(AppTheme.Typography.settingsCaption)
      .foregroundStyle(AppTheme.ProfileBasics.errorText)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, AppTheme.Space.xs)
      .padding(.vertical, AppTheme.Space.xxs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(AppTheme.ProfileBasics.errorBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(AppTheme.ProfileBasics.errorStroke, lineWidth: 1)
      )
      // Motion: subtle opacity fade on error appearance; identity when Reduce Motion is on.
      .transition(reduceMotion ? AnyTransition.identity : AnyTransition.opacity)
  }

  // MARK: - Load states

  private var loadingView: some View {
    ProgressView()
      .accessibilityLabel("Loading profile")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func loadFailedView(message: String) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      Text(message)
        .font(AppTheme.Typography.settingsBody)
        .foregroundStyle(AppTheme.ProfileBasics.errorText)
        .multilineTextAlignment(.center)

      Button("Retry") {
        flow?.retryLoad()
      }
      .font(AppTheme.Typography.settingsBodySemibold)
      .accessibilityLabel("Retry loading profile")
    }
    .padding(AppTheme.Space.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
