// FLRecipe — the SwiftUI screen.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
//
// Craft rules this file encodes (the Recipe mock + the binding constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius, photo geometry through PhotoLayoutRule —
//   the screen contains no visual value of its own.
// - Density: the document is a reading surface with dense lists —
//   `Density.deciding` frames the document, `Density.dense` the
//   ingredient rows and step stack (the token doc names ingredient lists
//   dense).
// - The servings stepper rescales every line; the base numbers are never
//   shown instead.
// - The step flow is numbered, one step at a time, with the count and one
//   Next/Skip control; other cooks' notes show only while cooking.
// - The record flow opens when the last step completes; rating and the
//   one-line difference live there; save and share are host effects with
//   a preview before anything is published.
// - Text-kind actions wrap to 44 pt minimum; motion is a fade, dropped
//   under Reduce Motion.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct RecipeView: View {

    @Binding var state: RecipeViewState
    let onIntent: (RecipeIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: Binding<RecipeViewState>, onIntent: @escaping (RecipeIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
                    if state.heroCaption != nil {
                        heroPhoto
                    }
                    titleBlock
                    statsRow
                    servingsControl
                    actionButton
                    ingredientsSection
                    methodSection
                    if !state.tips.isEmpty {
                        tipsSection
                    }
                    if !state.related.isEmpty {
                        relatedSection
                    }
                }
                .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(reduceMotion ? nil : .fl(.fade), value: state.currentStepIndex)
        }
        .sheet(isPresented: recordBinding) {
            RecordSheet(state: $state, onIntent: onIntent)
                .flScheme(scheme)
        }
        .accessibilityIdentifier("fl.recipe.screen")
    }

    // MARK: Hero, title, stats

    private var heroPhoto: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                Text(state.heroCaption ?? "")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(height: CGFloat(PhotoLayoutRule.heroIdealHeight), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("fl.recipe.hero")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .flType(.dishTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.recipe.title")
                .accessibilityAddTraits(.isHeader)
            Text("\(state.publisherDisplay) · \(state.revisionDisplay)")
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                .accessibilityIdentifier("fl.recipe.byline")
        }
    }

    private var statsRow: some View {
        Text(state.statsDisplay)
            .flType(.fitCount)
            .flTracking(.fitCount)
            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            .accessibilityIdentifier("fl.recipe.stats")
    }

    // MARK: Servings

    private var servingsControl: some View {
        HStack(spacing: 16) {
            Text(state.primaryActionTitle)
                .flType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            Spacer()
            stepper
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.recipe.servingsRow")
    }

    private var stepper: some View {
        HStack(spacing: 12) {
            Button {
                onIntent(.setServings(state.targetServings - 1))
            } label: {
                Image(systemName: "minus")
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Fewer servings")
            .accessibilityIdentifier("fl.recipe.servingsMinus")
            Text("\(state.targetServings)")
                .flType(.fitCount)
                .flTracking(.fitCount)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.recipe.servingsValue")
            Button {
                onIntent(.setServings(state.targetServings + 1))
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("More servings")
            .accessibilityIdentifier("fl.recipe.servingsPlus")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(state.targetServings) servings")
    }

    private var actionButton: some View {
        FLButton(
            .primary,
            state.isCooking ? "Cooking…" : state.primaryActionTitle,
            haptic: .mediumCommit
        ) {
            if !state.isCooking { onIntent(.beginCook) }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: CGFloat(Density.deciding.actionClearance ?? 48))
        .accessibilityIdentifier("fl.recipe.primaryAction")
    }

    // MARK: Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Ingredients")
                .accessibilityIdentifier("fl.recipe.ingredientsLabel")
            ForEach(state.ingredients) { ingredient in
                FLQuantityRow(
                    name: ingredient.name,
                    quantity: state.scaledQuantityDisplay(for: ingredient),
                    state: ingredient.isInKitchen ? .have : .missing
                )
                .accessibilityIdentifier("fl.recipe.ingredient.\(ingredient.id)")
                if let swap = ingredient.swapDisplay {
                    Text(swap)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .padding(.leading, 12)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("fl.recipe.swap.\(ingredient.id)")
                }
            }
        }
    }

    // MARK: Method

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                FLSectionLabel("Method")
                Spacer()
                if let count = state.stepCountDisplay {
                    Text(count)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.recipe.stepCount")
                }
            }
            ForEach(Array(state.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(index: index, step: step)
            }
            if state.isCooking {
                HStack(spacing: 12) {
                    FLButton(.primary, "Next", haptic: .lightConfirm) {
                        onIntent(.nextStep)
                    }
                    .accessibilityIdentifier("fl.recipe.next")
                    FLButton(.secondary, "Skip") {
                        onIntent(.skipStep)
                    }
                    .accessibilityIdentifier("fl.recipe.skip")
                }
                .padding(.top, 8)
            }
        }
        .accessibilityIdentifier("fl.recipe.method")
    }

    private func stepRow(index: Int, step: RecipeViewState.Step) -> some View {
        let isCurrent = state.currentStepIndex == index
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .flType(.fitCount)
                    .flTracking(.fitCount)
                    .foregroundStyle(
                        isCurrent ? Theme.swiftColor(.yolkInk, in: scheme)
                            : Theme.swiftColor(.ink2, in: scheme)
                    )
                    .frame(width: 24, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.row.rawValue))
                            .fill(isCurrent ? Theme.swiftColor(.yolk, in: scheme)
                                : Theme.swiftColor(.rule2, in: scheme))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .flType(.cookStep)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .accessibilityIdentifier("fl.recipe.step.\(step.id)")
                    Text(step.body)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                }
            }
            if let caption = step.photoCaption {
                stepPhotoArea(caption)
            }
            // Other cooks' notes show only while cooking; they disappear
            // once the record opens.
            if state.showsStepNotes, let note = step.cookNote {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(Theme.swiftColor(.ink, in: scheme))
                        .frame(width: 2)
                    Text(note)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note: \(note)")
                .accessibilityIdentifier("fl.recipe.stepNote.\(step.id)")
            }
        }
        .padding(.vertical, 8)
        .opacity(state.currentStepIndex == nil || isCurrent ? 1 : 0.45)
    }

    private func stepPhotoArea(_ caption: String) -> some View {
        // Part 7 audit: this area had a fixed 120 pt frame whose inner
        // derivation re-capped against the frame's own height, rendering
        // ~48 pt. It now uses the shared in-card treatment — full-width
        // 3:2 through PhotoLayoutRule, the same treatment as the Table
        // card's photo and Explore's thumbnails.
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat(Radius.row.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
            Text(caption)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                .padding(.horizontal, 12)
        }
        .aspectRatio(CGFloat(PhotoLayoutRule.aspectRatio), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: Tips and related

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FLSectionLabel("Tips from cooks")
                .accessibilityIdentifier("fl.recipe.tipsLabel")
            ForEach(Array(state.tips.enumerated()), id: \.offset) { index, tip in
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(Theme.swiftColor(.ink, in: scheme))
                        .frame(width: 2)
                    Text(tip)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note: \(tip)")
                .accessibilityIdentifier("fl.recipe.tip.\(index)")
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FLSectionLabel("Cooks also made")
                .accessibilityIdentifier("fl.recipe.relatedLabel")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                    ForEach(state.related) { related in
                        Button {
                            onIntent(.openRelated(recipeID: related.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(related.title)
                                    .flType(.body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                                    .multilineTextAlignment(.leading)
                                Text(related.fitLine)
                                    .flType(.fitCount)
                                    .flTracking(.fitCount)
                                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                            }
                            .padding(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                                    .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
                            )
                        }
                        .accessibilityIdentifier("fl.recipe.related.\(related.id)")
                    }
                }
            }
        }
    }

    private var recordBinding: Binding<Bool> {
        Binding(get: { state.showsRecord }, set: { shown in
            if !shown { onIntent(.dismissRecord) }
        })
    }
}

/// The cook record: rating, the one-line difference, and the host-owned
/// save and share (share previews first — nothing publishes directly).
private struct RecordSheet: View {

    @Binding var state: RecipeViewState
    let onIntent: (RecipeIntent) -> Void

    @Environment(\.flScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
            Text("How did it go?")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.recipe.recordTitle")

            VStack(alignment: .leading, spacing: 8) {
                FLSectionLabel("Rating")
                HStack(spacing: 8) {
                    ForEach(1...RecipeBounds.maxRating, id: \.self) { star in
                        Button {
                            onIntent(.setRating(star))
                        } label: {
                            Image(systemName: (state.rating.map { $0 >= star } ?? false)
                                ? "star.fill" : "star")
                                .foregroundStyle(Theme.swiftColor(.yolk, in: scheme))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("\(star) of \(RecipeBounds.maxRating)")
                        .accessibilityIdentifier("fl.recipe.rating.\(star)")
                    }
                }
                .accessibilityElement(children: .contain)
            }

            VStack(alignment: .leading, spacing: 8) {
                FLSectionLabel("What did you do differently?")
                TextField("used less salt", text: differentlyBinding)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .padding(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                            .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1)
                    )
                    .accessibilityIdentifier("fl.recipe.differently")
            }

            Text("Saves to your cookbook first. Sharing is a separate, previewed step — your pantry stays on this phone.")
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                .accessibilityIdentifier("fl.recipe.recordPrivacy")

            Spacer()
            FLButton(.primary, "Save", haptic: .mediumCommit) {
                onIntent(.saveRecord)
            }
            .frame(minHeight: CGFloat(Density.deciding.actionClearance ?? 48))
            .accessibilityIdentifier("fl.recipe.recordSave")
            FLButton(.secondary, "Share to a table…") {
                onIntent(.shareRecord)
            }
            .accessibilityIdentifier("fl.recipe.recordShare")
        }
        .padding(CGFloat(Density.deciding.sideMargin))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.swiftColor(.bg, in: scheme).ignoresSafeArea())
        .presentationDetents([.large])
    }

    private var differentlyBinding: Binding<String> {
        Binding(
            get: { state.didDifferently },
            set: { onIntent(.setDifferently($0)) }
        )
    }
}
#endif
