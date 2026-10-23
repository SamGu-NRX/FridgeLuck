import SwiftUI

/// The taste profile page (docs/spec/taste/SPEC.md §4): what FridgeLuck has learned about
/// the user's cooking, the evidence behind each sentence, and the corrections they can
/// make. Everything it draws comes from `TasteProfileScreenContent`.
struct TasteProfileView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var viewModel: TasteProfileViewModel
  @State private var pendingRowID: String?
  /// True only while a correction the user tapped is applying, so the first load and
  /// later reloads don't animate their layout.
  @State private var animatesCorrection = false
  @State private var appeared = false

  let onEditFoodPreferences: () -> Void

  init(viewModel: TasteProfileViewModel, onEditFoodPreferences: @escaping () -> Void) {
    _viewModel = State(initialValue: viewModel)
    self.onEditFoodPreferences = onEditFoodPreferences
  }

  var body: some View {
    let content = TasteProfileScreenContent.make(from: viewModel)

    ScrollView {
      Group {
        switch content {
        case .loading:
          TasteProfileLoadingView()
        case .empty:
          FLEmptyState(
            title: TasteProfileScreenContent.emptyTitle,
            message: TasteProfileScreenContent.emptyMessage,
            systemImage: "fork.knife"
          )
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("taste_profile_empty")
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.vertical, AppTheme.Space.md)
        case .failed:
          FLEmptyState(
            title: "Couldn't load your taste profile",
            message: "Your corrections are kept. Try loading it again.",
            systemImage: "exclamationmark.triangle.fill",
            actionTitle: "Retry",
            action: { Task { await viewModel.load() } }
          )
          .accessibilityIdentifier("taste_profile_error")
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.vertical, AppTheme.Space.md)
        case .loaded(let sections, let actionError):
          loaded(sections: sections, actionError: actionError)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("taste_profile_screen")
    }
    // A corrected row leaves its section and lands in Corrected; animating the layout shows
    // where it went. Under Reduce Motion the rows switch places without moving.
    .animation(
      animatesCorrection && !reduceMotion ? AppMotion.standard : nil, value: content.rowLayout)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Taste Profile")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    // Runs again when Food Preferences pops back, so edited restrictions show at once.
    .task { await viewModel.load() }
    .onChange(of: actionErrorText(content)) { _, message in
      if let message { AccessibilityNotification.Announcement(message).post() }
    }
    // VoiceOver may still be on the loading spinner when the error replaces it.
    .onChange(of: content == .failed) { _, failed in
      if failed {
        AccessibilityNotification.Announcement("Couldn't load your taste profile.").post()
      }
    }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  // MARK: - Loaded

  private func loaded(
    sections: [TasteProfileScreenContent.Section], actionError: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      if let actionError {
        Label(actionError, systemImage: "exclamationmark.circle.fill")
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.accent)
          .padding(.horizontal, AppTheme.Space.page)
          .transition(.opacity)
      }
      ForEach(sections) { section in
        sectionView(section)
      }
    }
    .padding(.vertical, AppTheme.Space.md)
  }

  private func sectionView(_ section: TasteProfileScreenContent.Section) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Text(section.title)
        .font(.system(.subheadline, design: .serif, weight: .medium))
        .foregroundStyle(AppTheme.textSecondary)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { divider }
          rowView(row)
            .transition(.opacity)
        }
        if let placeholder = section.placeholder {
          Text(placeholder)
            .font(AppTheme.Typography.settingsDetail)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Space.md)
        }
        if section.linksToFoodPreferences {
          divider
          foodPreferencesLink
        }
      }
      .background(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .fill(AppTheme.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
      )

      if let footer = section.footer {
        FLSettingsFootnote(text: footer)
      }
    }
    .padding(.horizontal, AppTheme.Space.page)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("taste_profile_section_\(section.id)")
  }

  private var divider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.22))
      .frame(height: 1)
      .padding(.leading, AppTheme.Space.md)
      .accessibilityHidden(true)
  }

  // MARK: - Row

  private func rowView(_ row: TasteProfileScreenContent.Row) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(row.sentence)
          .font(AppTheme.Typography.settingsBody)
          .foregroundStyle(row.isStruckThrough ? AppTheme.textSecondary : AppTheme.textPrimary)
          .strikethrough(row.isStruckThrough, color: AppTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail = row.detail {
          Text(detail)
            .font(AppTheme.Typography.label)
            .monospacedDigit()
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(row.accessibilityLabel)
      .accessibilityIdentifier("taste_profile_row_\(row.id)")

      if !row.actions.isEmpty {
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(row.actions, id: \.self) { action in
            actionButton(action, row: row)
          }
        }
      }
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, row.actions.isEmpty ? AppTheme.Space.md : AppTheme.Space.xxs)
  }

  private func actionButton(
    _ action: TasteProfileRowAction, row: TasteProfileScreenContent.Row
  ) -> some View {
    let emphasized = action == .markWrong
    return Button {
      run(action, on: row.source)
    } label: {
      Text(action.title)
        .font(AppTheme.Typography.settingsCaptionMedium)
        .foregroundStyle(emphasized ? AppTheme.accent : AppTheme.textPrimary)
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.xs)
        .background(
          Capsule(style: .continuous)
            .fill(emphasized ? AppTheme.accent.opacity(0.10) : AppTheme.surfaceMuted)
        )
        // The pill stays compact; the tap target is the full 44pt row height.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(pendingRowID != nil)
    .accessibilityHint(action.accessibilityHint)
    .accessibilityIdentifier("taste_profile_\(action.identifierStem)_\(row.id)")
  }

  private var foodPreferencesLink: some View {
    Button(action: onEditFoodPreferences) {
      HStack(spacing: AppTheme.Space.sm) {
        Text("Edit in Food Preferences")
          .font(AppTheme.Typography.settingsBody)
          .foregroundStyle(AppTheme.accent)
        Spacer(minLength: AppTheme.Space.sm)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, AppTheme.Space.md)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(FLPressableButtonStyle())
    .accessibilityHint("Allergies and diet are changed there.")
    .accessibilityIdentifier("taste_profile_edit_food_preferences")
  }

  // MARK: - Actions

  private func run(_ action: TasteProfileRowAction, on row: TasteProfileRow) {
    guard pendingRowID == nil else { return }
    pendingRowID = row.id
    animatesCorrection = true
    AppPreferencesStore.haptic(.light)
    Task {
      await viewModel.perform(action, on: row)
      pendingRowID = nil
      animatesCorrection = false
      if viewModel.errorMessage == nil {
        AccessibilityNotification.Announcement(action.confirmation).post()
      }
    }
  }

  private func actionErrorText(_ content: TasteProfileScreenContent) -> String? {
    guard case .loaded(_, let actionError) = content else { return nil }
    return actionError
  }
}

/// The first load reads the local database and usually finishes before a spinner would
/// register, so the spinner waits a moment before showing rather than flashing.
private struct TasteProfileLoadingView: View {
  @State private var showsSpinner = false

  var body: some View {
    ProgressView("Loading your taste profile")
      .font(AppTheme.Typography.settingsCaption)
      .tint(AppTheme.accent)
      .foregroundStyle(AppTheme.textSecondary)
      .frame(maxWidth: .infinity)
      .padding(.top, AppTheme.Space.xxl)
      .opacity(showsSpinner ? 1 : 0)
      .accessibilityIdentifier("taste_profile_loading")
      .task {
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(AppMotion.gentle) { showsSpinner = true }
      }
  }
}
