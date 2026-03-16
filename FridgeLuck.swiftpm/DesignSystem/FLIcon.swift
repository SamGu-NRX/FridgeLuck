import SwiftUI

// MARK: - Icon Source

enum FLIconSource: Hashable, Sendable {
  /// SF Symbol name (e.g. "checkmark.circle.fill")
  case system(String)
  /// Asset-catalog image name (e.g. "allergen_milk", "diet_vegan")
  case asset(String)
}

// MARK: - Icon Registry

enum FLIcon: Hashable, Sendable {

  // ─── Allergen group icons ────────────────────────────────────
  case allergenMilk
  case allergenEgg
  case allergenPeanut
  case allergenTreeNut
  case allergenSoy
  case allergenGluten
  case allergenFish
  case allergenShellfish
  case allergenSesame
  case allergenMustard

  // ─── Diet preference icons ──────────────────────────────────
  case dietClassic
  case dietPescatarian
  case dietVegetarian
  case dietVegan
  case dietKeto

  // ─── Resolved source ────────────────────────────────────────

  var source: FLIconSource {
    switch self {
    // Allergens
    case .allergenMilk: .asset("allergen_milk")
    case .allergenEgg: .asset("allergen_egg")
    case .allergenPeanut: .asset("allergen_peanut")
    case .allergenTreeNut: .asset("allergen_treenut")
    case .allergenSoy: .asset("allergen_soy")
    case .allergenGluten: .asset("allergen_gluten")
    case .allergenFish: .asset("allergen_fish")
    case .allergenShellfish: .asset("allergen_shellfish")
    case .allergenSesame: .asset("allergen_sesame")
    case .allergenMustard: .asset("allergen_mustard")

    // Diets
    case .dietClassic: .asset("diet_classic")
    case .dietPescatarian: .asset("diet_pescatarian")
    case .dietVegetarian: .asset("diet_vegetarian")
    case .dietVegan: .asset("diet_vegan")
    case .dietKeto: .asset("diet_keto")
    }
  }
}

// MARK: - Icon View

struct FLIconView: View {
  private let source: FLIconSource
  let size: CGFloat

  init(_ icon: FLIcon, size: CGFloat = 22) {
    self.source = icon.source
    self.size = size
  }

  init(_ source: FLIconSource, size: CGFloat = 22) {
    self.source = source
    self.size = size
  }

  var body: some View {
    switch source {
    case .system(let name):
      Image(systemName: name)
        .font(.system(size: size * 0.72, weight: .regular))
        .frame(width: size, height: size)
    case .asset(let name):
      Image(name)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
  }
}
