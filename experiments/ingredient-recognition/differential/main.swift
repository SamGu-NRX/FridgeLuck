// Differential probe: runs the app's ACTUAL IngredientLexicon +
// IngredientIdentityResolution (compiled from the app sources) over a fixed
// probe list and dumps JSONL results. The Python port (resolution/app_resolution.py)
// answers the same probes; any differing line is a port divergence.
//
// Build (repo worktree):
//   swiftc -O -o probe_resolver probe_resolver.swift \
//     ../../apps/ios/Capability/Core/Recognition/IngredientLexicon.swift \
//     ../../apps/ios/Capability/Core/Recognition/IngredientIdentityResolution.swift \
//     ../../apps/ios/Capability/Core/Recognition/ScanContracts.swift
// (ScanContracts supplies Detection/ScanProvenance referenced transitively if needed;
//  omit if the compile does not require it.)

import Foundation

// Shims: defined in ScanContracts.swift / IngredientCatalogResolver.swift, which
// import FLFeatureLogic / GRDB (not linkable in this probe). Only the types are
// needed here; their behavior is verified by the Python-port differential and the
// SQL-level catalog check documented in the report.
enum OCRMatchKind {
  case exact
  case fuzzy
}

enum IngredientCatalogMatching {
  case exact
  case allowPrefix
}

struct ProbeCase: Codable {
  let kind: String
  let input: String
}

func probe(_ kind: String, _ input: String) -> ProbeCase { ProbeCase(kind: kind, input: input) }

var probes: [ProbeCase] = []

// 1. All 103 FoodSeg103 class names through the app's full label resolution
let classNames = [
  "candy", "egg tart", "french fries", "chocolate", "biscuit", "popcorn", "pudding",
  "ice cream", "cheese butter", "cake", "wine", "milkshake", "coffee", "juice",
  "milk", "tea", "almond", "red beans", "cashew", "dried cranberries", "soy",
  "walnut", "peanut", "egg", "apple", "date", "apricot", "avocado", "banana",
  "strawberry", "cherry", "blueberry", "raspberry", "mango", "olives", "peach",
  "lemon", "pear", "fig", "pineapple", "grape", "kiwi", "melon", "orange",
  "watermelon", "steak", "pork", "chicken duck", "sausage", "fried meat", "lamb",
  "sauce", "crab", "fish", "shellfish", "shrimp", "soup", "hamburg", "pizza",
  " hanamaki baozi", "wonton dumplings", "noodles", "pie", "eggplant", "potato",
  "garlic", "cauliflower", "tomato", "kelp", "seaweed", "spring onion", "rape",
  "ginger", "okra", "lettuce", "pumpkin", "cucumber", "white radish", "carrot",
  "asparagus", "bamboo shoots", "broccoli", "celery stick", "cilantro mint",
  "snow peas", " cabbage", "bean sprouts", "pepper", "green beans",
  "French beans", "king oyster mushroom", "shiitake", "enoki mushroom",
  "oyster mushroom", "white button mushroom", "salad", "other ingredients",
  "rice", "pasta", "tofu", "bread", "corn", "onion", "scallion",
]
for name in classNames { probes.append(probe("label", name)) }

// 2. Curated lexicon behavior (underscores, casing, plural tails)
let lexiconProbes = [
  "egg", "Egg", "eggs", "tomato", "tomatoes", "bell_pepper", "bell pepper",
  "green_onion", "green onion", "spring onion", "frozen peas", "frozen_peas",
  "ground beef", "ground_beef", "canned_tuna", "tuna", "red pepper flakes",
  "red_pepper_flakes", "olive oil", "olive_oil", "yogurt", "yoghurt",
  "sweet potato", "sweet_potato", "sweet potatoes", "coconut milk", "sour cream",
  "soy sauce", "soy_sauce", "chickpea", "chickpeas", "oats", "oat", "lime",
  "tortilla", "tortillas", "black beans", "black_beans", "honey", "cumin",
  "cilantro", "zucchini", "zucchinis", "apple", "apples", "dairy", "chocolate",
  "s", "es", "ies", "", "  egg  ", "EGG", "FrEgGs",
]
for name in lexiconProbes { probes.append(probe("lexicon", name)) }

// 3. OCR text path: unsupported-phrase detection/masking + whole-phrase + token fallback
let ocrProbes = [
  "FRESH GREEN BEANS",
  "green beans",
  "Organic Green Beans 12oz",
  "celery stick",
  "celery sticks on the shelf",
  "oat milk",
  "oat milk carton",
  "free range eggs",
  "spring onions",
  "SIITRAKE",
  "french fries with ketchup",
  "peanut butter creamy",
  "low fat yogurt",
  "edamame",
  "1% milk",
  "garlic bread",
  "sweet chili sauce",
  "nothing edible here",
  "123",
  "tomato, carrot & garlic",
  "extra-firm tofu",
  "cottage cheese",
  "olive oil extra virgin",
  "sea salt",
  "black pepper",
  "hot dog buns",
  "kimchi",
  "napkin",
]
for text in ocrProbes {
  probes.append(probe("ocr", text))
}

// ---- run the app's actual code and print JSONL
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func jsonString(_ dict: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
  return String(data: data, encoding: .utf8)!
}

func j(_ v: Int64?) -> Any { v.map { String($0) } ?? NSNull() }

for p in probes {
  var out: [String: Any] = ["kind": p.kind, "input": p.input]
  switch p.kind {
  case "label":
    // full app precedence with a no-op correction closure
    let resolved = IngredientIdentityResolution.resolveLabel(
      p.input,
      userCorrection: { (_: String) -> Int64? in nil },
      curated: IngredientLexicon.resolve,
      catalog: { (_: String, _: IngredientCatalogMatching) -> Int64? in nil }  // catalog covered by the SQL-level differential
    )
    out["resolveLabel_curatedOnly"] = j(resolved)
    out["lexiconResolve"] = j(IngredientLexicon.resolve(p.input))
  case "lexicon":
    out["lexiconResolve"] = j(IngredientLexicon.resolve(p.input))
  case "ocr":
    out["unsupportedPhrases"] = IngredientLexicon.unsupportedFoodPhrases(in: p.input).joined(separator: "|")
    out["masked"] = IngredientLexicon.maskingUnsupportedFoodPhrases(p.input)
    if let m = IngredientLexicon.resolveFromTextDetailed(p.input) {
      out["matchId"] = String(m.ingredientId)
      out["matchKind"] = m.kind == .exact ? "exact" : "fuzzy"
      out["matchToken"] = m.matchedToken
    } else {
      out["matchId"] = NSNull()
      out["matchKind"] = NSNull()
      out["matchToken"] = NSNull()
    }
    out["resolveFromText"] = j(IngredientLexicon.resolveFromText(p.input))
  default:
    continue
  }
  print(jsonString(out))
}
