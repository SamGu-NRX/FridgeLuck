import FLFeatureLogic
import SwiftUI

struct GuestMealPlanView: View {
  @EnvironmentObject private var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var model = GuestMealPlanViewModel()
  @State private var isLoading = false
  @State private var showsRecipes = false
  @State private var stockExpanded = false

  var body: some View {
    Form {
      Section {
        Text("One serving of every recipe for each guest.")
          .font(AppTheme.Typography.bodyMedium)
        eventControls
        Button {
          showsRecipes = true
        } label: {
          LabeledContent("Choose recipes", value: "\(model.selectedRecipeIDs.count) selected")
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Choose recipes")
        .accessibilityValue("\(model.selectedRecipeIDs.count) selected")
        ForEach(model.selectedRecipes, id: \.databaseID) { item in
          Text(item.title)
            .font(AppTheme.Typography.bodyMedium)
          // Optional ingredients live here rather than in the chooser: inserted under a
          // just-toggled recipe there, they pushed the next recipe down under the finger.
          // Here they appear while the chooser sheet covers the screen.
          ForEach(model.optionalIngredientIDs(of: item), id: \.self) { ingredientID in
            optionalToggle(ingredientID, in: item)
          }
        }
      } header: {
        FLSectionHeader("Your table", icon: "person.2")
      }
      .listRowBackground(AppTheme.surface)

      Section {
        if isLoading {
          ProgressView("Loading recipes and inventory")
        } else {
          reviewContent
        }
      } header: {
        FLSectionHeader("Grocery review", icon: "basket")
      } footer: {
        Text("Only reviewed stock counts. Planning does not reserve or deduct food.")
          .foregroundStyle(AppTheme.textPrimary)
      }
      .listRowBackground(AppTheme.surface)

      if !model.uncountedLines.isEmpty {
        Section {
          ForEach(model.uncountedLines, id: \.self) { line in
            VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
              Text(line.ingredientName)
                .font(AppTheme.Typography.displayCaption)
              Text("\(line.recipeTitle) · \(uncountedReason(line.reason))")
                .font(AppTheme.Typography.bodySmall)
            }
            .padding(.vertical, AppTheme.Space.xs)
            .accessibilityElement(children: .combine)
          }
        } header: {
          FLSectionHeader("Check by hand", icon: "checklist")
        } footer: {
          Text("These aren't in the grocery totals above.")
            .foregroundStyle(AppTheme.textPrimary)
        }
        .listRowBackground(AppTheme.surface)
      }

      if !model.relevantLots.isEmpty {
        Section {
          DisclosureGroup(isExpanded: $stockExpanded) {
            ForEach(model.relevantLots) { lot in
              stockRow(lot)
            }
          } label: {
            Text("Review stock amounts")
              .frame(minHeight: 44)
          }
          .accessibilityValue(stockExpanded ? "Expanded" : "Collapsed")
        } footer: {
          Text("Use stock only in the same form as the recipe, such as raw or cooked. A missing expiry is not a freshness check. These edits apply only to this plan.")
            .foregroundStyle(AppTheme.textPrimary)
        }
        .listRowBackground(AppTheme.surface)
      }

      Section {
        Button {
          Task { await reload() }
        } label: {
          Label("Reload inventory", systemImage: "arrow.clockwise")
            .frame(minHeight: 44)
        }
        .disabled(isLoading)
        .accessibilityValue(isLoading ? "Loading" : "Ready")
        .accessibilityHint("Loads current recipes and stock and clears quantity confirmations.")
      } footer: {
        Text("Reloading clears amounts you reviewed here. Your recipe choices stay selected.")
          .foregroundStyle(AppTheme.textPrimary)
      }
      .listRowBackground(AppTheme.surface)
    }
    .font(AppTheme.Typography.bodyMedium)
    .foregroundStyle(AppTheme.textPrimary)
    .tint(AppTheme.accent)
    .scrollContentBackground(.hidden)
    .background(AppTheme.bg)
    .navigationTitle("Plan for guests")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    // Quantities should remain still while the host reads or edits them.
    .transaction { if reduceMotion { $0.animation = nil } }
    .sheet(isPresented: $showsRecipes) {
      GuestMealRecipeSelectionView(model: model)
    }
    .task {
      if model.snapshot == nil { await reload() }
    }
  }

  private func optionalToggle(_ ingredientID: Int64, in recipe: PlanCandidate) -> some View {
    let name = model.name(for: ingredientID)
    let included = model.optionalIDs[recipe.databaseID, default: []].contains(ingredientID)
    return Toggle(isOn: Binding(
      get: { model.optionalIDs[recipe.databaseID, default: []].contains(ingredientID) },
      set: { model.selectOptional(ingredientID, recipeID: recipe.databaseID, selected: $0) }
    )) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        Text(name)
        Text("Optional")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .padding(.leading, AppTheme.Space.md)
    .frame(minHeight: 44)
    .accessibilityLabel("Include \(name) in \(recipe.title)")
    .accessibilityValue(included ? "Included" : "Not included")
  }

  private var eventControls: some View {
    Group {
      // Explicit closures avoid Swift 6.3.3's actor thunk crash for bound method setters.
      Stepper(value: Binding(get: { model.guestCount }, set: { model.setGuests($0) }), in: 1...Int.max) {
        Text("Guests: \(model.guestCount)")
      }
      .frame(minHeight: 44)
      .accessibilityLabel("Guest count")
      .accessibilityValue("\(model.guestCount) guests")
      DatePicker("Meal date and time", selection: Binding(get: { model.eventDate }, set: { model.setDate($0) }))
        .frame(minHeight: 44)
        .accessibilityValue(model.eventDate.formatted(date: .abbreviated, time: .shortened))
    }
  }

  @ViewBuilder
  private var reviewContent: some View {
    switch model.review {
    case .empty:
      FLEmptyState(
        title: "Start with your menu",
        message: "Choose recipes above to see what you need for your guests.",
        systemImage: "fork.knife"
      )
    case .invalid(let message):
      Label("Review needed", systemImage: "exclamationmark.circle")
        .font(AppTheme.Typography.displayCaption)
      Text(message)
        .accessibilityLabel("Plan needs correction. \(message)")
    case .nothingWeighed:
      Label("No amounts to total", systemImage: "scalemass")
        .font(AppTheme.Typography.displayCaption)
      Text("None of the chosen ingredients list an amount in grams. Check them by hand below.")
    case .ready(let plan):
      if model.purchaseLines(plan).isEmpty {
        Label("No additional groceries needed", systemImage: "checkmark.circle")
          .font(AppTheme.Typography.displayCaption)
        Text("Your reviewed stock covers this menu.")
      }
      ForEach(model.sortedLines(plan), id: \.ingredientID) { line in
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text(model.name(for: line.ingredientID))
            .font(AppTheme.Typography.displayCaption)
          Text(lineStatus(line))
            .font(AppTheme.Typography.dataMedium)
          Text(GuestMealPlanView.stockLine(line))
            .font(AppTheme.Typography.bodySmall)
        }
        .padding(.vertical, AppTheme.Space.xs)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func stockRow(_ lot: InventoryLot) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("\(model.name(for: lot.ingredientId)) · \(lot.storageLocation.rawValue.capitalized)")
        .font(AppTheme.Typography.displayCaption)
      Text("Lot \(lot.id.map(String.init) ?? "without ID") · Added \(lot.acquiredAt.formatted(date: .abbreviated, time: .omitted))")
        .font(AppTheme.Typography.bodySmall)
      if let expiry = lot.expiresAt, expiry.timeIntervalSinceReferenceDate.isFinite {
        Text("Recorded expiry: \(expiry.formatted(date: .abbreviated, time: .shortened))")
          .font(AppTheme.Typography.bodySmall)
      } else if lot.expiresAt == nil {
        Text("No recorded expiry")
          .font(AppTheme.Typography.bodySmall)
      }
      if let id = lot.id {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text("Available amount in grams")
          TextField("Grams", text: Binding(
            get: { model.gramsText(for: lot) },
            set: { model.setGrams($0, lotID: id) }
          ))
          .keyboardType(.decimalPad)
          .textFieldStyle(.roundedBorder)
          .frame(minHeight: 44)
          .accessibilityLabel("\(model.name(for: lot.ingredientId)), lot \(id), available grams")
          .accessibilityValue("\(model.gramsText(for: lot)) grams")
        }
        Toggle("I checked the amount and ingredient form", isOn: Binding(
          get: { model.confirmedLotIDs.contains(id) },
          set: { model.confirmLot(id, confirmed: $0) }
        ))
        .frame(minHeight: 44)
        .disabled(!model.canConfirm(lot))
        .accessibilityLabel("Confirm \(model.name(for: lot.ingredientId)), lot \(id), amount and ingredient form")
        .accessibilityValue(model.confirmedLotIDs.contains(id) ? "Reviewed" : "Not reviewed")
      }
      Text(model.exclusionReason(for: lot) ?? "Included in reviewed stock")
        .font(AppTheme.Typography.bodySmall)
    }
    .padding(.vertical, AppTheme.Space.sm)
  }

  /// "Needed 150 g · Reviewed stock 50 g · 100 g to check below": estimated stock the host
  /// hasn't reviewed is named, so it reads as a check rather than as nothing.
  nonisolated static func stockLine(_ line: GuestMealPlanner.GroceryLine) -> String {
    var text = "Needed \(grams(line.requiredGrams)) · Reviewed stock \(grams(line.availableGrams))"
    if line.needsConfirmationGrams > 0 {
      text += " · \(grams(line.needsConfirmationGrams)) to check below"
    }
    return text
  }

  private func lineStatus(_ line: GuestMealPlanner.GroceryLine) -> String {
    guard line.missingGrams > 0 else { return "Covered by reviewed stock" }
    if model.isStaple(line.ingredientID) {
      return "Usually on hand · check for \(grams(line.missingGrams))"
    }
    return "Buy \(grams(line.missingGrams))"
  }

  private func uncountedReason(_ reason: GuestMealUncountedLine.Reason) -> String {
    switch reason {
    case .noGrams: "no amount in grams"
    case .notTracked: "not tracked in your Kitchen"
    }
  }

  private func grams(_ value: Double) -> String { Self.grams(value) }

  nonisolated static func grams(_ value: Double) -> String {
    if value > 0 && value < 0.1 { return "less than 0.1 g" }
    return "\(value.formatted(.number.precision(.fractionLength(0...1)))) g"
  }

  private func reload() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let queue = deps.appDatabase.dbQueue
      let now = Date()
      let snapshot = try await Task.detached(priority: .userInitiated) {
        try GuestMealSnapshot.load(from: queue, now: now)
      }.value
      model.replaceSnapshot(snapshot)
    } catch {
      model.loadingFailed()
    }
  }
}

private struct GuestMealRecipeSelectionView: View {
  @ObservedObject var model: GuestMealPlanViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""

  var body: some View {
    NavigationStack {
      Form {
        if let snapshot = model.snapshot {
          let recipes = snapshot.recipes.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          }
          if recipes.isEmpty {
            Text(snapshot.recipes.isEmpty ? "No recipes are available yet." : "No recipes match your search.")
          }
          ForEach(recipes, id: \.databaseID) { item in
            let id = item.databaseID
            Section {
              Toggle(item.title, isOn: Binding(
                get: { model.selectedRecipeIDs.contains(id) },
                set: { model.selectRecipe(id, selected: $0) }
              ))
              .frame(minHeight: 44)
              .accessibilityValue(model.selectedRecipeIDs.contains(id) ? "Selected" : "Not selected")
            }
            .listRowBackground(AppTheme.surface)
          }
          ForEach(model.selectedRecipeIDs.subtracting(Set(snapshot.recipes.map(\.databaseID))).sorted(), id: \.self) { id in
            Button("Remove unavailable recipe \(id)") { model.selectRecipe(id, selected: false) }
              .frame(minHeight: 44)
              .accessibilityValue("Selected recipe is unavailable")
          }
        } else {
          Text("Close this sheet and reload recipes and inventory to choose your menu.")
        }
      }
      .font(AppTheme.Typography.bodyMedium)
      .foregroundStyle(AppTheme.textPrimary)
      .tint(AppTheme.accent)
      .scrollContentBackground(.hidden)
      .background(AppTheme.bg)
      .navigationTitle("Choose recipes")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Search recipes")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityValue("\(model.selectedRecipeIDs.count) recipes selected")
        }
      }
    }
  }
}
