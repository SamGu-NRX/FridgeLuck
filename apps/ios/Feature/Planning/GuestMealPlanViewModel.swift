import Combine
import FLFeatureLogic
import Foundation

@MainActor
final class GuestMealPlanViewModel: ObservableObject {
  enum Review {
    case empty
    case invalid(String)
    case ready(GuestMealPlanner.Plan)
  }

  @Published private(set) var snapshot: GuestMealSnapshot?
  @Published private(set) var selectedRecipeIDs: Set<Int64> = []
  @Published private(set) var optionalIDs: [Int64: Set<Int64>] = [:]
  // Start with a host and one guest; the host can change the total before review.
  @Published private(set) var guestCount = 2
  @Published private(set) var eventDate: Date
  @Published private(set) var review: Review = .empty
  @Published private(set) var gramEdits: [Int64: String] = [:]
  @Published private(set) var confirmedLotIDs: Set<Int64> = []
  @Published private(set) var loadError: String?

  init(eventDate: Date = Date()) { self.eventDate = eventDate }

  func replaceSnapshot(_ snapshot: GuestMealSnapshot) {
    self.snapshot = snapshot
    // A new snapshot may contain changed stock. Never carry old quantity approval into it.
    gramEdits = [:]
    confirmedLotIDs = []
    loadError = nil
    recompute()
  }

  func loadingFailed() {
    let message = "Could not load recipes and inventory. Try reloading. Your menu choices are kept."
    loadError = message
    review = .invalid(message)
  }

  func selectRecipe(_ id: Int64, selected: Bool) {
    if selected { selectedRecipeIDs.insert(id) } else { selectedRecipeIDs.remove(id) }
    recompute()
  }

  func selectOptional(_ ingredientID: Int64, recipeID: Int64, selected: Bool) {
    if selected { optionalIDs[recipeID, default: []].insert(ingredientID) }
    else { optionalIDs[recipeID, default: []].remove(ingredientID) }
    recompute()
  }

  func setGuests(_ count: Int) {
    guestCount = count
    recompute()
  }

  func setDate(_ date: Date) {
    eventDate = date
    recompute()
  }

  func setGrams(_ text: String, lotID: Int64) {
    gramEdits[lotID] = text
    confirmedLotIDs.remove(lotID)
    recompute()
  }

  func confirmLot(_ id: Int64, confirmed: Bool) {
    if confirmed { confirmedLotIDs.insert(id) } else { confirmedLotIDs.remove(id) }
    recompute()
  }

  var selectedRecipes: [GuestMealRecipe] {
    snapshot?.recipes.filter { selectedRecipeIDs.contains($0.id ?? 0) } ?? []
  }

  var requiredIngredientIDs: Set<Int64> {
    Set(selectedRecipes.flatMap { item in
      item.ingredients.filter {
        $0.isRequired || optionalIDs[item.id ?? 0, default: []].contains($0.ingredientId)
      }.map(\.ingredientId)
    })
  }

  var relevantLots: [InventoryLot] {
    // IDs refer to the exact catalog ingredient. No name-based or cooked/raw substitution.
    snapshot?.lots.filter { requiredIngredientIDs.contains($0.ingredientId) } ?? []
  }

  func name(for id: Int64) -> String { snapshot?.ingredientNames[id] ?? "Ingredient \(id)" }

  func gramsText(for lot: InventoryLot) -> String {
    if let id = lot.id, let edit = gramEdits[id] { return edit }
    guard lot.remainingGrams.isFinite else { return "" }
    return lot.remainingGrams.formatted(.number.grouping(.never))
  }

  func parsedGrams(for lot: InventoryLot) -> Double? {
    guard let id = lot.id, let text = gramEdits[id] else {
      return lot.remainingGrams.isFinite && lot.remainingGrams >= 0 ? lot.remainingGrams : nil
    }
    guard let value = try? Double(text, format: .number.locale(.current)),
      value.isFinite, value >= 0 else { return nil }
    return value
  }

  func exclusionReason(for lot: InventoryLot) -> String? {
    if let expiry = lot.expiresAt, !expiry.timeIntervalSinceReferenceDate.isFinite {
      return "Excluded: correct the invalid expiry in your fridge, then reload inventory."
    }
    if let expiry = lot.expiresAt, expiry <= eventDate {
      return "Excluded: recorded expiry is at or before the meal."
    }
    if parsedGrams(for: lot) == nil { return "Excluded: enter a valid amount in grams." }
    if !confirmedLotIDs.contains(lot.id ?? 0) {
      return "Excluded until you review the amount and ingredient form."
    }
    return nil
  }

  func canConfirm(_ lot: InventoryLot) -> Bool {
    guard let id = lot.id, id > 0, parsedGrams(for: lot) != nil else { return false }
    guard let expiry = lot.expiresAt else { return true }
    return expiry.timeIntervalSinceReferenceDate.isFinite && expiry > eventDate
  }

  func sortedLines(_ plan: GuestMealPlanner.Plan) -> [GuestMealPlanner.GroceryLine] {
    plan.ingredients.sorted {
      if ($0.missingGrams > 0) != ($1.missingGrams > 0) { return $0.missingGrams > 0 }
      return name(for: $0.ingredientID).localizedStandardCompare(name(for: $1.ingredientID)) == .orderedAscending
    }
  }

  private func recompute() {
    if let loadError { review = .invalid(loadError); return }
    guard !selectedRecipeIDs.isEmpty else { review = .empty; return }
    do {
      guard selectedRecipes.count == selectedRecipeIDs.count else {
        throw GuestMealMapping.Issue(message: "A selected recipe is no longer available. Open Choose recipes and remove it.")
      }
      let recipes = try selectedRecipes.map {
        try GuestMealMapping.recipe($0, optionalIDs: optionalIDs[$0.id ?? 0, default: []])
      }
      let lots = try relevantLots.map { lot in
        guard let grams = parsedGrams(for: lot) else {
          throw GuestMealMapping.Issue(message: "\(name(for: lot.ingredientId)), lot \(lot.id ?? 0), needs a valid amount in grams. Review its stock below.")
        }
        var edited = lot
        edited.remainingGrams = grams
        return try GuestMealMapping.lot(
          edited, reviewedGrams: confirmedLotIDs.contains(lot.id ?? 0) ? grams : nil,
          name: name(for: lot.ingredientId)
        )
      }
      review = .ready(try GuestMealPlanner.plan(
        guestCount: guestCount, eventDate: eventDate, recipes: recipes, inventory: lots
      ))
    } catch let error as GuestMealMapping.Issue {
      review = .invalid(error.message)
    } catch let error as GuestMealPlanner.PlanningError {
      switch error {
      case .invalidGuestCount: review = .invalid("Enter at least one guest.")
      case .invalidEventDate: review = .invalid("Choose a valid meal date.")
      case .quantityOverflow(let id): review = .invalid("\(name(for: id)) exceeds the quantity limit. Reduce guests or remove a recipe.")
      case .duplicateLot(let id): review = .invalid("Stock lot \(id) appears twice. Reload inventory.")
      default: review = .invalid("The menu contains invalid data: \(error). Review your selections.")
      }
    } catch {
      review = .invalid(error.localizedDescription)
    }
  }
}
