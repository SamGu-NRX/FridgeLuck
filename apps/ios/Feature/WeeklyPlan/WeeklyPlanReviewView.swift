import SwiftUI
import FLFeatureLogic

/// The weekly-plan screen: editable review of the planner's proposal plus the
/// grouped shopping notes.
///
/// Pure presentation over `WeeklyPlanViewModel`, which drives the pure flow
/// reducer and the separate plan store. Nothing here recomputes implicitly:
/// the stale banner offers recompute, it never performs one.
struct WeeklyPlanReviewView: View {
  @EnvironmentObject private var deps: AppDependencies
  @State private var viewModel: WeeklyPlanViewModel?
  @State private var appeared = false

  var body: some View {
    Group {
      if let viewModel {
        content(viewModel)
      } else {
        ProgressView()
      }
    }
    .onAppear {
      guard !appeared else { return }
      appeared = true
      let store = (try? WeeklyPlanViewModel.defaultStore())
        ?? WeeklyPlanStore(directory: FileManager.default.temporaryDirectory)
      let model = WeeklyPlanViewModel(
        inventoryRepository: deps.inventoryRepository,
        recipeRepository: deps.recipeRepository,
        ingredientRepository: deps.ingredientRepository,
        userDataRepository: deps.userDataRepository,
        store: store)
      model.load()
      viewModel = model
    }
  }

  @ViewBuilder
  private func content(_ model: WeeklyPlanViewModel) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
        header(model)

        if let message = model.errorMessage {
          Text(message)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        if model.flowState.isStale {
          staleBanner(model)
        }

        if let rejection = model.flowState.rejectionReason {
          Text(rejection)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        if let plan = model.flowState.plan {
          slotsSection(model, plan: plan)
          feasibilitySection(model, plan: plan)
        } else {
          emptyState(model)
        }
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.vertical, AppTheme.Space.md)
    }
    .navigationTitle("Weekly plan")
  }

  // MARK: - Sections

  private func header(_ model: WeeklyPlanViewModel) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      FLSectionHeader(
        model.flowState.isAccepted ? "Your plan" : "Proposed plan",
        subtitle: "Read-only over your kitchen — nothing is reserved or used up",
        icon: "calendar")

      HStack {
        Button {
          model.recompute()
        } label: {
          Label(
            model.flowState.plan == nil ? "Create plan" : "Recompute",
            systemImage: "arrow.clockwise")
        }
        if model.flowState.plan != nil {
          Button(role: .destructive) {
            model.discard()
          } label: {
            Label("Remove", systemImage: "trash")
          }
        }
      }
      .buttonStyle(.bordered)
    }
  }

  private func staleBanner(_ model: WeeklyPlanViewModel) -> some View {
    FLCard(tone: .warning) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        Label("Your kitchen changed since this plan was made", systemImage: "exclamationmark.triangle")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Text("The plan still shows what was computed. Recompute to see a plan built from the kitchen as it is now.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func emptyState(_ model: WeeklyPlanViewModel) -> some View {
    Text(
      model.isLoading
        ? "Reading your kitchen…" : "No plan yet. Create one from what's in your kitchen."
    )
    .font(AppTheme.Typography.bodyMedium)
    .foregroundStyle(AppTheme.textSecondary)
  }

  private func slotsSection(_ model: WeeklyPlanViewModel, plan: WeeklyPlanRecord) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      ForEach(Array(plan.assignments.enumerated()), id: \.element.slotId) { index, assignment in
        slotCard(model, plan: plan, assignment: assignment, index: index)
      }
    }
  }

  private func slotCard(
    _ model: WeeklyPlanViewModel, plan: WeeklyPlanRecord,
    assignment: WeeklyPlanSlotAssignment, index: Int
  ) -> some View {
    FLCard(tone: .normal) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
        HStack {
          Text(assignment.slotLabel)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Spacer()
          Text(phaseLabel(model, plan))
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Text(assignment.recipeTitle)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
        Text("\(assignment.timeMinutes) min · serves \(assignment.servings)")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)

        ForEach(assignment.substitutions.indices, id: \.self) { subIndex in
          let substitution = assignment.substitutions[subIndex]
          Text(
            "Uses \(model.ingredientName(substitution.substituteIngredientId)) instead of \(model.ingredientName(substitution.plannedIngredientId))"
          )
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
        }

        HStack {
          Menu {
            ForEach(model.editCandidates, id: \.id) { candidate in
              Button(candidate.title) {
                model.edit(slotId: assignment.slotId, newRecipeId: candidate.id)
              }
            }
          } label: {
            Label("Replace", systemImage: "arrow.2.squarepath")
          }
          Button(role: .destructive) {
            model.remove(slotId: assignment.slotId)
          } label: {
            Label("Remove slot", systemImage: "minus.circle")
          }
        }
        .font(AppTheme.Typography.bodySmall)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(assignment.slotLabel): \(assignment.recipeTitle)")
  }

  @ViewBuilder
  private func feasibilitySection(_ model: WeeklyPlanViewModel, plan: WeeklyPlanRecord) -> some View {
    if plan.isFeasible {
      if !model.flowState.isAccepted {
        Button {
          model.accept()
        } label: {
          Label("Accept plan", systemImage: "checkmark.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }

      WeeklyPlanShortageView(
        shortages: plan.shortages,
        ingredientName: model.ingredientName,
        recipeTitle: model.recipeTitle)
    } else {
      FLCard(tone: .warning) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          FLSectionHeader("No workable plan yet", subtitle: "What is standing in the way", icon: "xmark.octagon")
          ForEach(Array(plan.violations.enumerated()), id: \.offset) { _, violation in
            Text(violation)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
    }
  }

  private func phaseLabel(_ model: WeeklyPlanViewModel, _ plan: WeeklyPlanRecord) -> String {
    if model.flowState.isAccepted { return "Accepted" }
    return plan.isFeasible ? "Draft" : "Infeasible draft"
  }
}
