import SwiftUI
import UIKit

/// Right-edge A–Z scrubber; drag to jump sections and show a letter overlay.
struct FLAlphabetScrubber: View {
  let availableLetters: Set<String>
  let onLetterChanged: (String) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var activeLetter: String?
  @State private var isDragging = false

  private let haptic = UISelectionFeedbackGenerator()
  private static let allLetters: [String] = {
    (65...90).map { String(UnicodeScalar($0)) } + ["#"]
  }()

  var body: some View {
    ZStack {
      letterStrip

      if isDragging, let activeLetter {
        letterOverlay(activeLetter)
          .transition(
            reduceMotion
              ? .opacity
              : .scale(scale: 0.6).combined(with: .opacity)
          )
      }
    }
    .animation(reduceMotion ? nil : AppMotion.cardSpring, value: isDragging)
    .animation(reduceMotion ? nil : AppMotion.quick, value: activeLetter)
  }

  // MARK: - Letter Strip

  private var letterStrip: some View {
    GeometryReader { geo in
      let totalHeight = geo.size.height
      let letterHeight = totalHeight / CGFloat(Self.allLetters.count)

      VStack(spacing: 0) {
        ForEach(Self.allLetters, id: \.self) { letter in
          let isActive = letter == activeLetter
          let isAvailable = availableLetters.contains(letter)

          Text(letter)
            .font(.system(size: 10, weight: isActive ? .black : .bold, design: .rounded))
            .foregroundStyle(
              isAvailable
                ? AppTheme.accent
                : AppTheme.oat.opacity(0.35)
            )
            .scaleEffect(isActive && !reduceMotion ? 1.3 : 1.0)
            .frame(maxWidth: .infinity)
            .frame(height: letterHeight)
            .accessibilityLabel("Jump to \(letter)")
        }
      }
      .frame(width: 18, height: totalHeight)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let index = Int(value.location.y / letterHeight)
            let clampedIndex = max(0, min(index, Self.allLetters.count - 1))
            let letter = Self.allLetters[clampedIndex]

            if !isDragging {
              isDragging = true
              haptic.prepare()
            }

            if letter != activeLetter {
              activeLetter = letter
              haptic.selectionChanged()
              if availableLetters.contains(letter) {
                onLetterChanged(letter)
              }
            }
          }
          .onEnded { _ in
            isDragging = false
            Task { @MainActor in
              try? await Task.sleep(nanoseconds: 300_000_000)
              if !isDragging {
                activeLetter = nil
              }
            }
          }
      )
    }
    .frame(width: 18)
  }

  // MARK: - Center Letter Overlay

  private func letterOverlay(_ letter: String) -> some View {
    Text(letter)
      .font(.system(size: 48, weight: .bold, design: .rounded))
      .foregroundStyle(AppTheme.textPrimary)
      .frame(width: 64, height: 64)
      .background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.20), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 12, x: 0, y: 4)
  }
}
