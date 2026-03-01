import SwiftUI

// MARK: - Demo Scenario Picker

/// 2-column grid of themed demo scenario cards. Each card has a gradient,
/// icon, title, subtitle, and ingredient chips. Tapping fires the selection.
struct DemoScenarioPicker: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scenarios: [DemoScenario]
  let onSelect: (DemoScenario) -> Void

  @State private var appeared = false

  private let columns = [
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
    GridItem(.flexible(), spacing: AppTheme.Space.sm),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("Pick a Fridge")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)

      Text("Each scenario loads different ingredients and unlocks different recipes.")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

      LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
        ForEach(Array(scenarios.enumerated()), id: \.element.id) { index, scenario in
          scenarioCard(scenario, index: index)
        }
      }
    }
    .onAppear {
      guard !reduceMotion, !appeared else { return }
      withAnimation(AppMotion.cardSpring.delay(0.1)) {
        appeared = true
      }
    }
  }

  private func scenarioCard(_ scenario: DemoScenario, index: Int) -> some View {
    Button {
      onSelect(scenario)
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        // Icon
        Image(systemName: scenario.icon)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 40, height: 40)
          .background(Circle().fill(.white.opacity(0.15)))

        // Title & subtitle
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(scenario.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(scenario.subtitle)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }

        // Ingredient chips
        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(scenario.ingredientNames.prefix(4), id: \.self) { name in
            Text(name)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.12), in: Capsule())
          }
          if scenario.ingredientNames.count > 4 {
            Text("+\(scenario.ingredientNames.count - 4)")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(.white.opacity(0.6))
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(.white.opacity(0.08), in: Capsule())
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .background(
        LinearGradient(
          colors: scenario.gradientColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(alignment: .topTrailing) {
        Circle()
          .fill(.white.opacity(0.05))
          .frame(width: 60, height: 60)
          .blur(radius: 15)
          .offset(x: 15, y: -10)
          .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
      .shadow(color: scenario.accentColor.opacity(0.15), radius: 8, x: 0, y: 4)
      .rotationEffect(.degrees(scenario.cardRotation), anchor: .center)
    }
    .buttonStyle(.plain)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 12)
    .animation(
      reduceMotion
        ? nil : AppMotion.cardSpring.delay(Double(index) * AppMotion.staggerDelay + 0.05),
      value: appeared
    )
  }
}
