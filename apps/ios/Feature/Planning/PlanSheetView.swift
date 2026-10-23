import FLFeatureLogic
import SwiftUI

/// The LeChef plan sheet (docs/spec/lechef/SPEC.md §3.2): a few dinners from what is in the
/// kitchen, and a shopping list for what they are short. Renders `PlanSheetContent` only, so
/// every word and number on screen comes from the view model's plan.
struct PlanSheetView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let model: PlanSheetViewModel
  /// Leaves the sheet for the groceries flow (the empty and nothing-fits states).
  let onAddGroceries: () -> Void

  @State private var expandedKitchenLines: Set<String> = []
  @Namespace private var dinnerRotor
  @Namespace private var lineRotor

  var body: some View {
    let content = PlanSheetContent(model)
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          header(content)
          if content.showsPlanControls {
            dinnerCountControl
          }
          ForEach(content.notes, id: \.self) { note in
            noteRow(note)
              .transition(.opacity)
          }
          stateBody(content)
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.xs)
        .padding(.bottom, AppTheme.Space.xl)
        // Content that changes under the user's finger (a swapped dinner, an added one, a new
        // state) moves into place instead of jumping. Under Reduce Motion nothing slides: the
        // layout changes at once.
        .animation(changeAnimation, value: content.dinners.map(\.id))
        .animation(changeAnimation, value: content.kind)
        .animation(changeAnimation, value: content.notes)
      }
      .scrollContentBackground(.hidden)
      .background(AppTheme.bg)
      .accessibilityRotor("Dinners") {
        ForEach(content.dinners) { card in
          AccessibilityRotorEntry(Text(card.title), id: card.id, in: dinnerRotor)
        }
      }
      // SPEC.md §3.2: per-line navigation. Collapsed kitchen lines are not on screen, so they
      // join the rotor once their dinner's list is open.
      .accessibilityRotor("Ingredients") {
        ForEach(content.dinners) { card in
          ForEach(rotorLines(card), id: \.id) { entry in
            AccessibilityRotorEntry(Text(entry.label), id: entry.id, in: lineRotor)
          }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if content.kind == .planned {
          actionBar(content)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("plan_sheet_done")
        }
      }
    }
    .presentationDragIndicator(.visible)
    .task {
      if model.state == .idle, model.errorMessage == nil { await model.load() }
    }
    .onChange(of: model.saveStatus) { old, new in
      if old == .saving, new == .saved { AppPreferencesStore.notification(.success) }
      if old == .saving, new == .failed { AppPreferencesStore.notification(.error) }
    }
  }

  /// 0.24 s strong ease-out for moves. Under Reduce Motion no animation at all: a container
  /// animation would also slide the siblings of whatever appears.
  private var changeAnimation: Animation? {
    reduceMotion ? nil : AppMotion.standard
  }

  private var cardTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
  }

  private var isLargeType: Bool { dynamicTypeSize.isAccessibilitySize }

  // MARK: - Header and controls

  private func header(_ content: PlanSheetContent) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text(content.title)
        .font(AppTheme.Typography.displayMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .contentTransition(reduceMotion ? .opacity : .numericText())
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("plan_sheet_title")
      Text(content.subtitle)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private var dinnerCountControl: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      // Explicit closures avoid Swift 6.3.3's actor thunk crash for bound method setters.
      Stepper(
        value: Binding(get: { model.dinnerCount }, set: { model.setDinnerCount($0) }),
        in: 1...7
      ) {
        HStack(spacing: AppTheme.Space.xs) {
          Text("Dinners")
            .font(AppTheme.Typography.bodyLarge)
            .foregroundStyle(AppTheme.textPrimary)
          Text("\(model.dinnerCount)")
            .font(AppTheme.Typography.dataMedium)
            .monospacedDigit()
            .foregroundStyle(AppTheme.textPrimary)
            .contentTransition(reduceMotion ? .opacity : .numericText())
        }
      }
      .frame(minHeight: 44)
      .accessibilityLabel("Dinners to plan")
      .accessibilityValue("\(model.dinnerCount)")
      .accessibilityIdentifier("plan_sheet_dinner_count")
      if model.isWeeklyHorizon {
        Text("Five or more dinners can repeat a dish and plan leftovers nights.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.xs)
    .background(
      AppTheme.surfaceMuted.opacity(0.5),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
  }

  private func noteRow(_ note: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
      Image(systemName: "info.circle")
        .foregroundStyle(AppTheme.accent)
        .accessibilityHidden(true)
      Text(note)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(AppTheme.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      AppTheme.accentMuted,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  // MARK: - States

  @ViewBuilder
  private func stateBody(_ content: PlanSheetContent) -> some View {
    switch content.kind {
    case .loading:
      VStack(spacing: AppTheme.Space.md) {
        ProgressView()
          .controlSize(.large)
          .tint(AppTheme.accent)
        Text("Reading your kitchen…")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.xxl)
      .accessibilityElement(children: .combine)
    case .failed:
      FLEmptyState(
        title: content.headline ?? "",
        message: content.message ?? "",
        systemImage: "exclamationmark.triangle.fill",
        actionTitle: "Try again"
      ) {
        Task { await model.load() }
      }
    case .emptyKitchen:
      FLEmptyState(
        title: content.headline ?? "",
        message: content.message ?? "",
        systemImage: "refrigerator",
        actionTitle: "Add groceries",
        action: onAddGroceries)
    case .noRecipes:
      FLEmptyState(
        title: content.headline ?? "",
        message: content.message ?? "",
        systemImage: "fork.knife")
    case .nothingFits:
      nothingFits(content)
    case .planned:
      ForEach(content.dinners) { card in
        dinnerCard(card)
          .transition(cardTransition)
      }
      shoppingSlip(content, heading: "Shopping list")
    }
  }

  /// Shopping-list-first (SPEC.md §3.2): the shop comes before the dinners it would make, and
  /// those dinners are labelled as needing it, never offered as cookable now.
  private func nothingFits(_ content: PlanSheetContent) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Image(systemName: "cart")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.dustyRose)
          .accessibilityHidden(true)
        Text(content.headline ?? "")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(content.message ?? "")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)

      shoppingSlip(content, heading: "Shop first")

      FLSectionHeader("What that shop makes", icon: "fork.knife")
      ForEach(content.dinners) { card in
        dinnerCard(card)
          .transition(cardTransition)
      }
      FLSecondaryButton("Add groceries", systemImage: "plus", action: onAddGroceries)
    }
  }

  // MARK: - Dinner card

  private func dinnerCard(_ card: PlanSheetContent.DinnerCard) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          HStack(alignment: .firstTextBaseline) {
            Text(card.positionLabel)
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: AppTheme.Space.xs)
            if let timeText = card.timeText {
              Label(timeText, systemImage: "clock")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          Text(card.title)
            .font(AppTheme.Typography.displaySmall)
            .foregroundStyle(AppTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Text(card.fitText)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityRotorEntry(id: card.id, in: dinnerRotor)

        if card.canChangeServings {
          Stepper(
            value: Binding(
              get: { card.servings },
              set: { model.setServings($0, forDinnerAt: card.index) }),
            in: 1...12
          ) {
            Text(card.servings == 1 ? "1 serving" : "\(card.servings) servings")
              .font(AppTheme.Typography.bodyMedium)
              .monospacedDigit()
              .foregroundStyle(AppTheme.textPrimary)
              .contentTransition(reduceMotion ? .opacity : .numericText())
          }
          .frame(minHeight: 44)
          .accessibilityLabel("Servings for \(card.title)")
          .accessibilityValue(card.servings == 1 ? "1 serving" : "\(card.servings) servings")
        }

        if !card.toBuy.isEmpty {
          lineGroup("To buy", icon: "cart", rows: card.toBuy, cardID: card.id)
        }
        if !card.substitutions.isEmpty {
          lineGroup(
            "Reviewed swaps", icon: "arrow.left.arrow.right", rows: card.substitutions,
            cardID: card.id)
        }
        if !card.toCheck.isEmpty {
          lineGroup("Check", icon: "checklist", rows: card.toCheck, cardID: card.id)
        }
        if !card.fromKitchen.isEmpty {
          kitchenLines(card)
        }

        if card.canSwap {
          Button {
            model.replaceDinner(at: card.index)
          } label: {
            Label("Swap this dinner", systemImage: "arrow.triangle.2.circlepath")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.accent)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(FLPressableButtonStyle())
          .accessibilityLabel("Swap \(card.title)")
          .accessibilityHint("Picks a different recipe for \(card.positionLabel.lowercased()). The other dinners stay.")
          .accessibilityIdentifier("plan_sheet_swap_\(card.index)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// What the kitchen covers, collapsed to a count: the lines that need action stay open above.
  private func kitchenLines(_ card: PlanSheetContent.DinnerCard) -> some View {
    let expanded = expandedKitchenLines.contains(card.id)
    let count = card.fromKitchen.count
    return VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      Button {
        withAnimation(
          reduceMotion
            ? nil
            : (expanded ? AppMotion.settingsDisclosureCollapse : AppMotion.settingsDisclosureExpand)
        ) {
          if expanded {
            expandedKitchenLines.remove(card.id)
          } else {
            expandedKitchenLines.insert(card.id)
          }
        }
      } label: {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "refrigerator")
            .foregroundStyle(AppTheme.sage)
            .accessibilityHidden(true)
          Text("From your kitchen · \(count) \(count == 1 ? "ingredient" : "ingredients")")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textPrimary)
          Spacer(minLength: AppTheme.Space.xs)
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("From your kitchen, \(count) \(count == 1 ? "ingredient" : "ingredients")")
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint(expanded ? "Hides what this dinner uses" : "Shows what this dinner uses")

      if expanded {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          ForEach(Array(card.fromKitchen.enumerated()), id: \.offset) { index, row in
            lineRow(row)
              .accessibilityRotorEntry(
                id: Self.lineID(card.id, "From your kitchen", index), in: lineRotor)
          }
        }
        .padding(.leading, AppTheme.Space.lg)
        .transition(.opacity)
      }
    }
  }

  private func lineGroup(
    _ title: String, icon: String, rows: [PlanSheetContent.LineRow], cardID: String
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Label(title, systemImage: icon)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textPrimary)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        lineRow(row)
          .padding(.leading, AppTheme.Space.lg)
          .accessibilityRotorEntry(id: Self.lineID(cardID, title, index), in: lineRotor)
      }
    }
  }

  private static func lineID(_ cardID: String, _ group: String, _ index: Int) -> String {
    "\(cardID)|\(group)|\(index)"
  }

  /// Rotor entries in on-screen order: the groups that are always open, then the kitchen
  /// lines when expanded.
  private func rotorLines(_ card: PlanSheetContent.DinnerCard) -> [(id: String, label: String)] {
    var groups: [(String, [PlanSheetContent.LineRow])] = [
      ("To buy", card.toBuy), ("Reviewed swaps", card.substitutions), ("Check", card.toCheck),
    ]
    if expandedKitchenLines.contains(card.id) {
      groups.append(("From your kitchen", card.fromKitchen))
    }
    return groups.flatMap { group, rows in
      rows.enumerated().map { index, row in
        (Self.lineID(card.id, group, index), "\(group): \(row.name), \(row.detail)")
      }
    }
  }

  @ViewBuilder
  private func lineRow(_ row: PlanSheetContent.LineRow) -> some View {
    let layout =
      isLargeType
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Space.xxxs))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs))
    layout {
      Text(row.name)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if !isLargeType { Spacer(minLength: AppTheme.Space.xs) }
      Text(row.detail)
        .font(AppTheme.Typography.dataSmall)
        .monospacedDigit()
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(isLargeType ? .leading : .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Shopping slip

  /// The one shopping list: every short line across the dinners, merged per ingredient by the
  /// allocator. Drawn as a grocery slip, with a torn edge and amounts in a right-hand column.
  private func shoppingSlip(_ content: PlanSheetContent, heading: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .firstTextBaseline) {
        FLSectionHeader(heading, icon: "basket")
        Spacer()
        if !content.shopping.isEmpty {
          let toBuy = content.shopping.filter { !$0.usuallyOnHand }.count
          Text(toBuy == 1 ? "1 item" : "\(toBuy) items")
            .font(AppTheme.Typography.label)
            .monospacedDigit()
            .foregroundStyle(AppTheme.textSecondary)
            .contentTransition(reduceMotion ? .opacity : .numericText())
        }
      }

      Line()
        .stroke(AppTheme.oat.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .frame(height: 1)
        .accessibilityHidden(true)

      if let empty = content.shoppingEmptyText {
        Label(empty, systemImage: "checkmark.circle")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
      } else {
        ForEach(content.shopping) { row in
          shoppingRow(row)
        }
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surfaceElevated,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.35), lineWidth: 1))
  }

  private func shoppingRow(_ row: PlanSheetContent.ShoppingRow) -> some View {
    let layout =
      isLargeType
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Space.xxxs))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs))
    return layout {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(row.name)
          .font(AppTheme.Typography.bodyLarge)
          .strikethrough(row.usuallyOnHand, color: AppTheme.textSecondary)
          .foregroundStyle(row.usuallyOnHand ? AppTheme.textSecondary : AppTheme.textPrimary)
        if row.usuallyOnHand {
          Text("You usually have this")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      if !isLargeType { Spacer(minLength: AppTheme.Space.xs) }
      Text(row.amountText)
        .font(AppTheme.Typography.dataSmall)
        .monospacedDigit()
        .foregroundStyle(row.usuallyOnHand ? AppTheme.textSecondary : AppTheme.textPrimary)
    }
    .padding(.vertical, AppTheme.Space.xxs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
  }

  // MARK: - Actions

  private func actionBar(_ content: PlanSheetContent) -> some View {
    FLActionBar {
      if let failure = content.saveFailureText {
        Text(failure)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.dustyRose)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity)
      }
      if let save = content.save {
        FLPrimaryButton(
          saveTitle(save),
          systemImage: save == .saved ? "checkmark" : nil,
          isEnabled: model.canSave
        ) {
          Task { await model.save() }
        }
        .accessibilityIdentifier("plan_sheet_save")
      }
      Button("Plan different dinners") {
        model.regenerate()
      }
      .font(AppTheme.Typography.label)
      .foregroundStyle(AppTheme.accent)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityHint("Replaces every dinner with a different pick from your kitchen.")
      .accessibilityIdentifier("plan_sheet_regenerate")
    }
    .padding(.horizontal, AppTheme.Space.page)
    .background(AppTheme.bg)
    .animation(changeAnimation, value: content.saveFailureText)
  }

  private func saveTitle(_ save: PlanSheetContent.SaveControl) -> String {
    switch save {
    case .save: "Save plan"
    case .saving: "Saving…"
    case .saved: "Saved"
    case .retry: "Save again"
    }
  }
}

/// A horizontal hairline, stroked by the caller (the slip's dashed tear line).
private struct Line: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    }
  }
}
