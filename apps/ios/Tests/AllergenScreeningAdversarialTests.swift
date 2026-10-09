import XCTest
import FLFeatureLogic

/// Adversarial tests for the pinned `AllergenScreening` contract.
///
/// Contract under test (`FLFeatureLogic.AllergenScreening.rejection(title:instructions:avoidingIngredients:)`):
///   - Iterate `avoidingIngredients` in list order; for each name check the title
///     first, then the instructions; the first match wins and is reported as a
///     `Rejection` carrying the avoided ingredient, the actual substring matched,
///     and the field it was found in.
///   - Per name: trim; skip the name if it is empty or contains no alphanumeric
///     character; tokenize into words on non-alphanumeric characters; each word
///     with >= 2 characters ending in "s" becomes stem + "s?", every other word
///     becomes word + "(?:es|s)?"; tokens join with "[\W_]+"; the pattern is
///     wrapped in `\b...\b` and searched with [.regularExpression, .caseInsensitive].
///   - An empty avoid list always returns nil.
///
/// Every test name states the contract edge it pins. Behavior the contract does
/// not pin (e.g. y-to-ies plurals such as berry/berries) is deliberately not
/// asserted.
final class AllergenScreeningAdversarialTests: XCTestCase {

    // MARK: - Substring traps

    func test_rejection_avoidWordBlocksStandaloneOccurrence_eggBlocksEggWashWithMatchedTermEgg() {
        let result = AllergenScreening.rejection(
            title: "Egg wash",
            instructions: "",
            avoidingIngredients: ["egg"]
        )
        XCTAssertEqual(
            result,
            AllergenScreening.Rejection(avoidedIngredient: "egg", matchedTerm: "Egg", field: .title)
        )
    }

    func test_rejection_avoidWordDoesNotBlockWordsMerelyContainingIt_eggSparesEggplantEggcupAndBeggs() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "Roasted eggplant", instructions: "", avoidingIngredients: ["egg"]),
            "substring 'egg' inside 'eggplant' must not block"
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "Eggcup display", instructions: "", avoidingIngredients: ["egg"]),
            "substring 'egg' inside 'eggcup' must not block"
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "", instructions: "three beggs fried", avoidingIngredients: ["egg"]),
            "substring 'egg' inside 'beggs' must not block"
        )
    }

    /// Universal invariant: an avoid name must match its own literal occurrence.
    /// A recipe naming an avoided ingredient verbatim is not safe to show, so nil
    /// would be a contract violation — including for degenerate-looking names.
    func test_rejection_avoidNameAlwaysBlocksItsOwnLiteralOccurrence_selfMatchInvariant() {
        let names = [
            "egg", "Peanuts", "tomato", "tomatoes", "oats", "glass",
            "tree nut", "2% milk", "vit.c", "Café", "s",
        ]
        for name in names {
            XCTAssertNotNil(
                AllergenScreening.rejection(title: name, instructions: "", avoidingIngredients: [name]),
                "avoid name '\(name)' must block its own literal occurrence"
            )
        }
    }

    // MARK: - Plural handling

    /// Plural avoid name must also block the singular: "Peanuts" stems to
    /// "Peanut" + "s?", so the singular "peanut" is caught too.
    func test_rejection_pluralAvoidNameBlocksSingularText_peanutsBlocksPeanut() {
        let result = AllergenScreening.rejection(
            title: "crunchy peanut",
            instructions: "",
            avoidingIngredients: ["Peanuts"]
        )
        XCTAssertEqual(result?.matchedTerm, "peanut")
        XCTAssertEqual(result?.avoidedIngredient, "Peanuts")
        XCTAssertEqual(result?.field, .title)
    }

    /// Singular avoid name must block the -es plural via the "(?:es|s)?" suffix.
    func test_rejection_esFormingAvoidNameBlocksEsPluralText_tomatoBlocksTomatoes() {
        let result = AllergenScreening.rejection(
            title: "",
            instructions: "sun-dried tomatoes",
            avoidingIngredients: ["tomato"]
        )
        XCTAssertEqual(result?.matchedTerm, "tomatoes")
        XCTAssertEqual(result?.field, .instructions)
    }

    func test_rejection_pluralAvoidNameBlocksBareSingularText_oatsBlocksOatButNotOatmeal() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "rolled oat", instructions: "", avoidingIngredients: ["oats"])?.matchedTerm,
            "oat"
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "oatmeal cookies", instructions: "", avoidingIngredients: ["oats"]),
            "the trailing \\b must keep 'oats' from matching inside 'oatmeal'"
        )
    }

    /// The pinned stem rule drops exactly one trailing "s": "tomatoes" becomes
    /// "tomatoe" + "s?", so the pattern requires the trailing "e" and cannot match
    /// the bare singular "tomato". This asymmetry is pinned behavior of the
    /// contract as written (the stem rule never strips "es").
    func test_rejection_esPluralAvoidNameStemsOnlyTheFinalS_tomatoesDoesNotMatchBareTomato() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "one tomato", instructions: "", avoidingIngredients: ["tomatoes"]),
            "'tomatoes' stems to 'tomatoe', which requires the trailing 'e' — bare 'tomato' must not match"
        )
        XCTAssertNotNil(
            AllergenScreening.rejection(title: "two tomatoes", instructions: "", avoidingIngredients: ["tomatoes"]),
            "'tomatoes' must still match its own plural form"
        )
    }

    // MARK: - Word-internal matches

    /// A word-internal substring must never block: the leading \b stops "glass"
    /// from matching inside "eyeglass".
    func test_rejection_wordInternalSubstringDoesNotBlock_glassSparesEyeglass() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "eyeglass frames", instructions: "", avoidingIngredients: ["glass"]),
            "'glass' inside 'eyeglass' must not block"
        )
        XCTAssertNotNil(
            AllergenScreening.rejection(title: "a glass of water", instructions: "", avoidingIngredients: ["glass"]),
            "'glass' as a standalone word must block"
        )
    }

    // MARK: - Multi-word names and separators

    /// Tokens join with "[\W_]+", so any run of non-word characters between the
    /// words matches — spaces, hyphens, and other separators alike.
    func test_rejection_multiWordNameMatchesAcrossSeparators_treeNutBlocksTreeNutsHyphenatedAndRunsWithSpaces() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "crushed tree nuts", instructions: "", avoidingIngredients: ["tree nut"])?.matchedTerm,
            "tree nuts"
        )
        XCTAssertEqual(
            AllergenScreening.rejection(title: "Tree-Nut crust", instructions: "", avoidingIngredients: ["tree nut"])?.matchedTerm,
            "Tree-Nut"
        )
        XCTAssertEqual(
            AllergenScreening.rejection(title: "tree   nut", instructions: "", avoidingIngredients: ["tree nut"])?.matchedTerm,
            "tree   nut"
        )
        XCTAssertEqual(
            AllergenScreening.rejection(title: "tree nut allergy", instructions: "", avoidingIngredients: ["Tree-Nut"])?.matchedTerm,
            "tree nut",
            "separators in the avoid name itself tokenize away, so 'Tree-Nut' still matches 'tree nut'"
        )
    }

    func test_rejection_multiWordNameMatchesAcrossNewlinesInInstructions_treeNutBlocksTreeNewlineNut() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "", instructions: "chop the tree\nnut finely", avoidingIngredients: ["tree nut"])?.matchedTerm,
            "tree\nnut"
        )
    }

    func test_rejection_multiWordNameSparesConcatenatedLetters_treeNutDoesNotBlockTreehugger() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "the treehugger special", instructions: "", avoidingIngredients: ["tree nut"]),
            "'[\W_]+' requires a real separator; glued letters must not match"
        )
    }

    func test_rejection_digitLeadingNameRequiresSeparatorBetweenWords_2PercentMilkBlocksWith2PercentMilkButNot212PercentMilk() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "made with 2% milk", instructions: "", avoidingIngredients: ["2% milk"]),
            AllergenScreening.Rejection(avoidedIngredient: "2% milk", matchedTerm: "2% milk", field: .title)
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "no such thing as 212% milk", instructions: "", avoidingIngredients: ["2% milk"]),
            "digits are word characters, so '212% milk' is not a separator match for '2% milk'"
        )
    }

    // MARK: - Regex metacharacters

    /// Names are tokenized on non-alphanumeric characters before the pattern is
    /// built, so a "." in an avoid name never reaches the regex engine as a
    /// wildcard: "vit.c" matches "Vit C" (dot-as-separator) but not "VITXCORE".
    func test_rejection_metacharactersInNamesAreTokenizedLiterally_vitDotCBlocksVitCToppingButNotVitXCore() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "Vit C topping", instructions: "", avoidingIngredients: ["vit.c"])?.matchedTerm,
            "Vit C"
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "VITXCORE bar", instructions: "", avoidingIngredients: ["vit.c"]),
            "a regex-dot wildcard would match 'VITXCORE'; tokenization must prevent that"
        )
    }

    // MARK: - Accents and case folding

    /// [.caseInsensitive] folds accents too: "Café" matches "CAFÉ".
    func test_rejection_accentedNamesCaseFold_cafeBlocksUppercaseCAFE() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "CAFÉ CREME", instructions: "", avoidingIngredients: ["Café"]),
            AllergenScreening.Rejection(avoidedIngredient: "Café", matchedTerm: "CAFÉ", field: .title)
        )
    }

    // MARK: - Degenerate names

    /// A one-character word never gets the stem treatment (stemming "s" would
    /// build a pattern matching at every word boundary); it still forms a bounded
    /// token and therefore matches a standalone "s".
    func test_rejection_singleLetterNameFormsBoundedTokenAndMatchesStandaloneS_sizeSIsBlocked() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "size S", instructions: "", avoidingIngredients: ["s"]),
            AllergenScreening.Rejection(avoidedIngredient: "s", matchedTerm: "S", field: .title)
        )
    }

    func test_rejection_singleLetterNameIsNeverStemmed_sCannotMatchInsideOrdinaryWords() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "hot soup", instructions: "", avoidingIngredients: ["s"]),
            "without stemming, 's' has no (?:es|s)? expansion and \\b blocks a match inside 'soup'"
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "brush strokes", instructions: "", avoidingIngredients: ["s"])
        )
    }

    /// Empty, whitespace-only, and punctuation-only names are skipped — but a
    /// skipped name must not abort the search: later list entries still apply.
    func test_rejection_emptyWhitespaceAndPunctuationOnlyNamesAreSkipped_withoutAbortingLaterListEntries() {
        XCTAssertNil(AllergenScreening.rejection(title: "egg salad", instructions: "", avoidingIngredients: [""]))
        XCTAssertNil(AllergenScreening.rejection(title: "egg salad", instructions: "", avoidingIngredients: ["   "]))
        XCTAssertNil(AllergenScreening.rejection(title: "egg salad", instructions: "", avoidingIngredients: ["!!!"]))

        let result = AllergenScreening.rejection(
            title: "egg salad",
            instructions: "",
            avoidingIngredients: ["", "   ", "!!!", "egg"]
        )
        XCTAssertEqual(result?.avoidedIngredient, "egg")
        XCTAssertEqual(result?.matchedTerm, "egg")
    }

    /// A name with no alphanumeric character at all is skipped even when the same
    /// character sequence appears in the text.
    func test_rejection_namesWithoutAlphanumericCharactersAreSkipped_emojiOnlyNameNeverMatches() {
        XCTAssertNil(
            AllergenScreening.rejection(title: "🚀🚀🚀", instructions: "", avoidingIngredients: ["🚀"]),
            "emoji are not alphanumeric, so the name is skipped entirely"
        )
    }

    /// Non-alphanumeric characters in a name tokenize away, so "🚀milk" applies
    /// as "milk" — an implementation must not discard the whole name.
    func test_rejection_nameWithNonAlphanumericPrefixStillAppliesItsAlphanumericWord_emojiPrefixedMilkBlocksMilk() {
        XCTAssertNotNil(
            AllergenScreening.rejection(title: "fresh milk", instructions: "", avoidingIngredients: ["🚀milk"])
        )
        XCTAssertNil(
            AllergenScreening.rejection(title: "fresh almond drink", instructions: "", avoidingIngredients: ["🚀milk"])
        )
    }

    // MARK: - Ordering rules

    /// List order wins: "egg" is first in the avoid list, so its match is
    /// reported even though "peanut" appears earlier in the title text.
    func test_rejection_firstListedIngredientWins_evenWhenLaterIngredientAppearsEarlierInTheText() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "Peanut butter egg cups", instructions: "", avoidingIngredients: ["egg", "peanut"]),
            AllergenScreening.Rejection(avoidedIngredient: "egg", matchedTerm: "egg", field: .title)
        )
    }

    /// Ingredient list order outranks field order: an earlier name's instructions
    /// match beats a later name's title match.
    func test_rejection_ingredientListOrderOutranksFieldOrder_earlierNameInstructionsBeatLaterNameTitle() {
        XCTAssertEqual(
            AllergenScreening.rejection(title: "peanut brittle", instructions: "fry the egg", avoidingIngredients: ["egg", "peanut"]),
            AllergenScreening.Rejection(avoidedIngredient: "egg", matchedTerm: "egg", field: .instructions)
        )
    }

    /// Per name the title is checked before the instructions.
    func test_rejection_titleIsCheckedBeforeInstructions_sameIngredientInBothFieldsResolvesToTitle() {
        let instructionsOnly = AllergenScreening.rejection(
            title: "Sunday pancakes", instructions: "Beat one egg.", avoidingIngredients: ["egg"]
        )
        XCTAssertEqual(instructionsOnly?.field, .instructions)
        XCTAssertEqual(instructionsOnly?.matchedTerm, "egg")

        let both = AllergenScreening.rejection(
            title: "PEANUT oil", instructions: "add peanut butter", avoidingIngredients: ["peanut"]
        )
        XCTAssertEqual(both?.field, .title)
        XCTAssertEqual(both?.matchedTerm, "PEANUT", "the title hit (with its own casing) wins over the instructions hit")
    }

    // MARK: - Rejection payload

    func test_rejection_rejectionCarriesExactAvoidedIngredientMatchedTermAndField_andPinnedRawValues() {
        XCTAssertEqual(AllergenScreening.Rejection.Field.title.rawValue, "title")
        XCTAssertEqual(AllergenScreening.Rejection.Field.instructions.rawValue, "instructions")

        let result = AllergenScreening.rejection(
            title: "",
            instructions: "Stir in chopped PEANUTS last.",
            avoidingIngredients: ["Peanuts"]
        )
        XCTAssertEqual(
            result,
            AllergenScreening.Rejection(avoidedIngredient: "Peanuts", matchedTerm: "PEANUTS", field: .instructions)
        )
    }

    /// matchedTerm is the actual substring found in the text — the avoid name's
    /// casing is not copied over.
    func test_rejection_matchedTermIsTheActualTextSubstring_notTheAvoidName() {
        let result = AllergenScreening.rejection(
            title: "crunchy peanut", instructions: "", avoidingIngredients: ["PEANUT"]
        )
        XCTAssertEqual(result?.matchedTerm, "peanut")
        XCTAssertEqual(result?.avoidedIngredient, "PEANUT")
    }

    /// Padding is trimmed before the pattern is built. The contract does not pin
    /// whether a padded avoid name is reported trimmed or verbatim, so
    /// avoidedIngredient is intentionally unasserted here.
    func test_rejection_paddedNameIsTrimmedForPatternBuilding_andStillBlocks() {
        let result = AllergenScreening.rejection(
            title: "egg salad", instructions: "", avoidingIngredients: ["  egg  "]
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchedTerm, "egg")
        XCTAssertEqual(result?.field, .title)
    }

    // MARK: - Empty avoid list

    func test_rejection_emptyAvoidListAlwaysReturnsNil_evenForAbsurdInputs() {
        XCTAssertNil(AllergenScreening.rejection(title: "", instructions: "", avoidingIngredients: []))
        XCTAssertNil(AllergenScreening.rejection(title: "egg milk peanut", instructions: "eggs eggs eggs", avoidingIngredients: []))
        XCTAssertNil(AllergenScreening.rejection(title: "🍅🥜🥚", instructions: "", avoidingIngredients: []))
        XCTAssertNil(
            AllergenScreening.rejection(
                title: String(repeating: "egg ", count: 1_000),
                instructions: String(repeating: "peanuts ", count: 1_000),
                avoidingIngredients: []
            )
        )
    }

    // MARK: - Long inputs

    /// 12k words, every one a near-miss ("peanut42x" contains "peanut" but never
    /// as a bounded word), with the only real match at the very end — the worst
    /// case for a scanner that stops at the first hit.
    func test_rejection_12kNearMissWordsWithOnlyMatchAtTheEnd_completeWithinBudget() {
        var words = (0..<12_000).map { "peanut\($0)x" }
        words.append("finally peanut")
        let text = words.joined(separator: " ")

        let clock = ContinuousClock()
        var result: AllergenScreening.Rejection?
        let elapsed = clock.measure {
            result = AllergenScreening.rejection(title: "", instructions: text, avoidingIngredients: ["peanut"])
        }

        XCTAssertEqual(result?.matchedTerm, "peanut")
        XCTAssertEqual(result?.field, .instructions)
        XCTAssertLessThan(elapsed, Duration.seconds(10), "screening 12k near-miss words must complete quickly")
    }

    /// 12k near-miss words with no match at all — the full-scan path.
    func test_rejection_12kNearMissWordsWithNoMatch_completeWithinBudget() {
        let text = (0..<12_000).map { "peanut\($0)x" }.joined(separator: " ")

        let clock = ContinuousClock()
        var result: AllergenScreening.Rejection?
        let elapsed = clock.measure {
            result = AllergenScreening.rejection(title: "", instructions: text, avoidingIngredients: ["peanut"])
        }

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, Duration.seconds(10), "screening 12k near-miss words must complete quickly")
    }
}
