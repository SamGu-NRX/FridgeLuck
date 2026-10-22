import Foundation

enum MacroDisplayFormatting {
  static func rounded(_ value: Double) -> Int {
    Int(value.rounded())
  }
}
