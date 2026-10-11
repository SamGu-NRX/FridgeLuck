import Foundation
import RecipeExportLogic
import Testing

/// Literal-string checks for the recipe amount-export logic. Every expected
/// string is written out exactly as the export must render it.
struct RecipeExportCheckTests {
  private func makeRow(
    name: String,
    isRequired: Bool = true,
    amount: Double? = nil,
    unit: String? = nil,
    note: String? = nil,
    swap: String? = nil,
    ratio: Double? = nil
  ) -> RecipeExportRowIntake {
    RecipeExportRowIntake(
      name: name,
      isRequired: isRequired,
      amount: amount,
      unit: unit,
      replacementNote: note,
      substitutedName: swap,
      substitutionRatio: ratio
    )
  }

  private func makeIntake(
    recipeName: String = "Pancakes",
    originalServings: Int? = 4,
    sourceURL: URL? = nil,
    rows: [RecipeExportRowIntake],
    excluded: RecipeExportExcludedFields = RecipeExportExcludedFields()
  ) -> RecipeExportIntake {
    RecipeExportIntake(
      recipeName: recipeName,
      originalServings: originalServings,
      sourceURL: sourceURL,
      rows: rows,
      excluded: excluded
    )
  }

  // MARK: 1. Non-unit substitution ratio applies once, on top of serving scale.

  @Test func nonUnitRatioScalesQuantityOnce() throws {
    // 4/3 ratio (1.333…): 50 g × 1 × 4/3 = 66.666… → '66.7 g'.
    let fourThirds = try RecipeExportPreparer.prepare(
      intake: makeIntake(rows: [makeRow(name: "Flour", amount: 50, unit: "g", swap: "Margarine", ratio: 4.0 / 3.0)]),
      exportedServings: 4,
      presentation: .metricGrams
    )
    #expect(fourThirds.rows[0].quantityText == "66.7 g")

    // The same arithmetic with a plain 1.33 ratio: 50 × 1.33 = 66.5.
    let plain = try RecipeExportPreparer.prepare(
      intake: makeIntake(rows: [makeRow(name: "Flour", amount: 50, unit: "g", swap: "Margarine", ratio: 1.33)]),
      exportedServings: 4,
      presentation: .metricGrams
    )
    #expect(plain.rows[0].quantityText == "66.5 g")
  }

  // MARK: 2. Fractional servings header and one-pass scaling, full golden render.

  @Test func fractionalServingsGoldenRender() throws {
    let intake = makeIntake(
      recipeName: "Pancakes",
      originalServings: 4,
      sourceURL: URL(string: "https://example.com/pancakes"),
      rows: [makeRow(name: "Flour", amount: 400, unit: "g")]
    )
    let doc = try RecipeExportPreparer.prepare(
      intake: intake,
      exportedServings: 2.5,
      presentation: .metricGrams
    )
    let expected = [
      "Pancakes — ingredient amounts",
      "Servings: 2.5 (recipe base: 4)",
      "",
      "1. Flour — 250 g — Required",
      "",
      "Source: https://example.com/pancakes",
      "Amount list only — cooking instructions are not included.",
    ].joined(separator: "\n")
    #expect(doc.renderedText() == expected)

    // Only http(s) source links may be exported; other (or missing) schemes drop.
    let ftpDoc = try RecipeExportPreparer.prepare(
      intake: makeIntake(
        recipeName: "Pancakes",
        originalServings: 4,
        sourceURL: URL(string: "ftp://example.com/pancakes"),
        rows: [makeRow(name: "Flour", amount: 400, unit: "g")]
      ),
      exportedServings: 2.5,
      presentation: .metricGrams
    )
    #expect(ftpDoc.sourceURL == nil)
    #expect(!ftpDoc.renderedText().contains("Source:"))
  }

  // MARK: 3. Imperial presentation converts gram quantities to ounces only.

  @Test func imperialConvertsGramQuantitiesToOunces() throws {
    let doc = try RecipeExportPreparer.prepare(
      intake: makeIntake(rows: [makeRow(name: "Butter", amount: 250, unit: "g")]),
      exportedServings: 4,
      presentation: .imperialOunces
    )
    #expect(doc.rows[0].quantityText == "8.8 oz")
  }

  // MARK: 4. Stable intake order, swap/note lines, byte-identical re-render.

  @Test func stableOrderAndDeterministicRender() throws {
    let intake = makeIntake(
      recipeName: "Golden Pancakes",
      originalServings: 4,
      rows: [
        makeRow(name: "Flour", amount: 400, unit: "g", swap: "Whole wheat flour", ratio: 1.5),
        makeRow(name: "Sugar", isRequired: false, amount: 30, unit: "g"),
        makeRow(name: "Vanilla", isRequired: false, amount: 2, unit: "tsp", note: "add at the end"),
      ]
    )
    let doc = try RecipeExportPreparer.prepare(intake: intake, exportedServings: 4, presentation: .metricGrams)
    let first = doc.renderedText()
    let again = try RecipeExportPreparer.prepare(intake: intake, exportedServings: 4, presentation: .metricGrams).renderedText()
    #expect(first == again)
    let expected = [
      "Golden Pancakes — ingredient amounts",
      "Servings: 4 (recipe base: 4)",
      "",
      "1. Flour — 600 g — Required",
      "   swap: Whole wheat flour (ratio 1.5)",
      "2. Sugar — 30 g — Optional",
      "3. Vanilla — 2 tsp — Optional",
      "   note: add at the end",
      "",
      "Amount list only — cooking instructions are not included.",
    ].joined(separator: "\n")
    #expect(first == expected)
  }

  // MARK: 5. Unicode names render verbatim; filenames strip accents, not transliterate.

  @Test func unicodeNamesRenderVerbatimAndSlugStripsAccents() throws {
    let doc = try RecipeExportPreparer.prepare(
      intake: makeIntake(
        recipeName: "Crème brûlée",
        originalServings: 4,
        rows: [makeRow(name: "味噌汁", amount: 500, unit: "g")]
      ),
      exportedServings: 2,
      presentation: .metricGrams
    )
    let text = doc.renderedText()
    #expect(text.contains("Crème brûlée — ingredient amounts"))
    #expect(text.contains("1. 味噌汁 — 250 g — Required"))
    #expect(RecipeExportFilename.defaultName(recipeName: "Crème brûlée", exportedServings: 2.5) == "creme-brulee-amounts-2p5-servings.txt")
  }

  // MARK: 6. Refusals for inconsistent reads and invalid servings.

  @Test func preparationRefusals() {
    #expect(throws: RecipeExportError.invalidOriginalServings(nil)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(originalServings: nil, rows: []), exportedServings: 4, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.invalidOriginalServings(0)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(originalServings: 0, rows: []), exportedServings: 4, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.invalidOriginalServings(-2)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(originalServings: -2, rows: []), exportedServings: 4, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.invalidExportServings(0)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(rows: []), exportedServings: 0, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.invalidExportServings(-1)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(rows: []), exportedServings: -1, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.invalidExportServings(.infinity)) {
      try RecipeExportPreparer.prepare(intake: makeIntake(rows: []), exportedServings: .infinity, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.inconsistentRecipeRead("recipe name missing")) {
      try RecipeExportPreparer.prepare(intake: makeIntake(recipeName: "", rows: []), exportedServings: 4, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.inconsistentRecipeRead("ingredient name missing")) {
      try RecipeExportPreparer.prepare(intake: makeIntake(rows: [makeRow(name: "")]), exportedServings: 4, presentation: .metricGrams)
    }
    #expect(throws: RecipeExportError.inconsistentRecipeRead("substitution ratio invalid")) {
      try RecipeExportPreparer.prepare(intake: makeIntake(rows: [makeRow(name: "Flour", swap: "Margarine", ratio: 0)]), exportedServings: 4, presentation: .metricGrams)
    }
  }

  // MARK: 7. Swap changes are drift; the prepared document itself never changes.

  @Test func swapDriftDetection() throws {
    let intake = makeIntake(rows: [makeRow(name: "Butter", amount: 200, unit: "g", swap: "Margarine", ratio: 1.2)])
    let doc = try RecipeExportPreparer.prepare(intake: intake, exportedServings: 4, presentation: .metricGrams)
    let before = doc.renderedText()

    let changedSwap = makeIntake(rows: [makeRow(name: "Butter", amount: 200, unit: "g", swap: "Vegan butter", ratio: 1.2)])
    #expect(RecipeExportDrift.isStale(liveIntake: changedSwap, prepared: doc) == true)
    #expect(doc.renderedText() == before)

    let changedName = makeIntake(recipeName: "Pancake heaven", originalServings: 4, rows: [makeRow(name: "Butter", amount: 200, unit: "g", swap: "Margarine", ratio: 1.2)])
    #expect(RecipeExportDrift.isStale(liveIntake: changedName, prepared: doc) == true)

    // Amount edits are not drift: the prepared document already carries its values.
    let changedAmount = makeIntake(rows: [makeRow(name: "Butter", amount: 999, unit: "g", swap: "Margarine", ratio: 1.2)])
    #expect(RecipeExportDrift.isStale(liveIntake: changedAmount, prepared: doc) == false)

    #expect(RecipeExportDrift.isStale(liveIntake: intake, prepared: doc) == false)
  }

  // MARK: 8. Session generation rules.

  @Test func sessionGenerationAndRetryRules() throws {
    var session = RecipeExportSession()
    #expect(session.status == .idle && session.prepared == nil && session.generation == 0)

    let doc = try RecipeExportPreparer.prepare(
      intake: makeIntake(rows: [makeRow(name: "Flour", amount: 100, unit: "g")]),
      exportedServings: 4,
      presentation: .metricGrams
    )

    let generation = session.beginPreparation()
    #expect(generation == 1)
    #expect(session.status == .preparing)

    // Stale-generation completion is discarded entirely.
    session.complete(doc, generation: 99)
    #expect(session.prepared == nil)
    #expect(session.status == .preparing)

    session.complete(doc, generation: generation)
    #expect(session.status == .prepared)
    #expect(session.prepared == doc)

    // A failed re-prepare preserves the prior prepared document.
    let failedGeneration = session.beginPreparation()
    #expect(failedGeneration == 2)
    session.fail(.recipeReadFailed, generation: failedGeneration)
    #expect(session.prepared == doc)
    #expect(session.status == .prepareFailed(.recipeReadFailed))

    // Cancel during preparing preserves content and records no failure.
    let cancelledGeneration = session.beginPreparation()
    #expect(session.status == .preparing)
    session.cancelPreparation()
    #expect(session.status == .prepared)
    #expect(session.prepared == doc)
    #expect(cancelledGeneration == 3)

    // A stale failure after cancel does not flip the status.
    session.fail(.recipeMissing, generation: 99)
    #expect(session.status == .prepared)

    session.noteInteraction(.saveCompleted)
    #expect(session.lastInteraction == .saveCompleted)
    session.noteInteraction(.shareSheetClosed)
    #expect(session.lastInteraction == .shareSheetClosed)

    // Cancelling with no prepared document falls back to idle.
    var fresh = RecipeExportSession()
    _ = fresh.beginPreparation()
    fresh.cancelPreparation()
    #expect(fresh.status == .idle)
    #expect(fresh.prepared == nil)
  }

  // MARK: 9. Excluded fields never reach the rendered text (sentinel control).

  @Test func excludedFieldsNeverReachRenderedText() throws {
    let excluded = RecipeExportExcludedFields(
      photoPath: "SENTINEL-PHOTO",
      journalNotes: "SENTINEL-JOURNAL",
      healthSummary: "SENTINEL-HEALTH",
      rating: "SENTINEL-RATING",
      databaseID: "SENTINEL-ID-12345",
      instructions: "SENTINEL-INSTRUCTIONS",
      ocrText: "SENTINEL-OCR"
    )
    let doc = try RecipeExportPreparer.prepare(
      intake: makeIntake(rows: [makeRow(name: "Flour", amount: 100, unit: "g")], excluded: excluded),
      exportedServings: 4,
      presentation: .metricGrams
    )
    #expect(!doc.renderedText().contains("SENTINEL-"))
  }

  // MARK: 10. Filename slug rules.

  @Test func filenameSlugRules() {
    #expect(RecipeExportFilename.defaultName(recipeName: "Pancakes!", exportedServings: 4) == "pancakes-amounts-4-servings.txt")
    #expect(RecipeExportFilename.defaultName(recipeName: "Crème! brûlée?? (extra)", exportedServings: 4) == "creme-brulee-extra-amounts-4-servings.txt")
    #expect(RecipeExportFilename.defaultName(recipeName: "", exportedServings: 4) == "recipe-amounts-4-servings.txt")
    #expect(RecipeExportFilename.defaultName(recipeName: "   ", exportedServings: 2.5) == "recipe-amounts-2p5-servings.txt")
  }

  // MARK: 11. Rows without a recorded amount render 'unspecified', never a number.

  @Test func missingAmountRendersUnspecified() throws {
    let intake = makeIntake(rows: [makeRow(name: "Cinnamon", isRequired: false, amount: nil, unit: nil)])
    let metric = try RecipeExportPreparer.prepare(intake: intake, exportedServings: 4, presentation: .metricGrams)
    #expect(metric.rows[0].quantityText == "unspecified")

    let imperial = try RecipeExportPreparer.prepare(intake: intake, exportedServings: 4, presentation: .imperialOunces)
    #expect(imperial.rows[0].quantityText == "unspecified")

    #expect(metric.renderedText().contains("1. Cinnamon — unspecified — Optional"))
    #expect(!metric.renderedText().contains("unspecified unspecified"))
  }
}
