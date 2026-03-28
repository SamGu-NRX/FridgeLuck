import SwiftUI

struct FLRapidNumericText: View {
  @Environment(\.font) private var font

  let value: String

  init(_ value: String) {
    self.value = value
  }

  var body: some View {
    Text(value)
      .font((font ?? .body).monospacedDigit())
  }
}
