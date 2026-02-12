import SwiftUI

/// Educational ingredient card with per-100g nutrition and storage guidance.
struct IngredientDetailSheet: View {
  let ingredient: Ingredient
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          titleSection
          macroSection
          detailsSection
        }
        .padding()
      }
      .navigationTitle("Ingredient")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var titleSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: spriteSymbolName())
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        Text(ingredient.displayName)
          .font(.title2.bold())
      }
      Text("\(Int(ingredient.calories)) kcal per 100g")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let description = ingredient.description, !description.isEmpty {
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
      }
    }
  }

  private var macroSection: some View {
    HStack(spacing: 12) {
      macroCard("Protein", value: "\(Int(ingredient.protein))g", color: .blue)
      macroCard("Carbs", value: "\(Int(ingredient.carbs))g", color: .green)
      macroCard("Fat", value: "\(Int(ingredient.fat))g", color: .red)
    }
  }

  private func macroCard(_ label: String, value: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(value)
        .font(.headline)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }

  private var detailsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let typicalUnit = ingredient.typicalUnit, !typicalUnit.isEmpty {
        detailRow(label: "Typical Unit", value: typicalUnit)
      }
      if let storageTip = ingredient.storageTip, !storageTip.isEmpty {
        detailRow(label: "Storage Tip", value: storageTip)
      }
      if let pairsWith = ingredient.pairsWith, !pairsWith.isEmpty {
        detailRow(label: "Pairs Well With", value: pairsWith)
      }
      if let notes = ingredient.notes, !notes.isEmpty {
        detailRow(label: "Notes", value: notes)
      }
      detailRow(label: "Fiber", value: "\(String(format: "%.1f", ingredient.fiber))g")
      detailRow(label: "Sugar", value: "\(String(format: "%.1f", ingredient.sugar))g")
      detailRow(label: "Sodium", value: "\(Int((ingredient.sodium * 1000).rounded()))mg")
    }
  }

  private func detailRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.body)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private func spriteSymbolName() -> String {
    let explicit = ingredient.spriteKey?.lowercased() ?? ""
    switch explicit {
    case "celery": return "leaf"
    case "lettuce": return "leaf.fill"
    case "carrot": return "leaf.arrow.circlepath"
    case "broccoli": return "tree.fill"
    case "tomato": return "circle.fill"
    case "cucumber", "zucchini": return "capsule.portrait.fill"
    case "onion", "green_onion": return "circle.grid.cross.fill"
    default: break
    }

    let group = ingredient.spriteGroup?.lowercased() ?? ""
    switch group {
    case "protein": return "fork.knife"
    case "vegetable": return "leaf"
    case "fruit": return "leaf.circle"
    case "grain_legume": return "takeoutbag.and.cup.and.straw.fill"
    case "dairy_egg": return "drop.fill"
    case "oil_fat": return "drop.triangle.fill"
    case "herb_spice": return "sparkles"
    case "nut_seed": return "smallcircle.filled.circle"
    case "condiment": return "line.3.horizontal.decrease.circle"
    default:
      return "square.grid.2x2"
    }
  }
}
