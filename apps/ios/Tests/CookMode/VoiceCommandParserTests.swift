import FLFeatureLogic
import XCTest

/// The offline five-word parser: what matches, what doesn't, and the timer grammar
/// (LeChef §4.3).
final class VoiceCommandParserTests: XCTestCase {
  private let parser = VoiceCommandParser()

  private func assertParses(_ phrase: String, _ expected: CookCommand, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(parser.parse(phrase), expected, message, file: file, line: line)
  }

  func testFiveWordTable() {
    assertParses("next", .next)
    assertParses("Next", .next)
    assertParses("back", .back)
    assertParses("go back", .back)
    assertParses("repeat", .repeatStep)
    assertParses("again", .repeatStep)
    assertParses("say that again", .repeatStep)
    assertParses("show", .show)
    assertParses("look at this", .show)
  }

  func testNormalization() {
    assertParses("Next.", .next)
    assertParses("  BACK  ", .back)
    assertParses("Repeat!", .repeatStep)
    assertParses("\"show\"", .show)
    assertParses("next, please", .unrecognized(phrase: "next, please"), "only whole utterances match — 'next, please' is not in the vocabulary")
  }

  func testTimerTable() {
    let accepted: [(String, Int)] = [
      ("timer 2 minutes", 120),
      ("timer two minutes", 120),
      ("2 minutes", 120),
      ("2 mins", 120),
      ("timer 1 minute", 60),
      ("three minutes", 180),
      ("twenty-five minutes", 1500),
      ("1.5 minutes", 90),
      ("one and a half minutes", 90),
      ("180 minutes", 10_800),
      ("one hundred eighty minutes", 10_800),
    ]

    for (phrase, seconds) in accepted {
      XCTAssertEqual(parser.parse(phrase), .timer(seconds: seconds), phrase)
    }

    // The §4.3 grammar carries minutes only, and requires a number.
    let rejected = [
      "timer 90 seconds",
      "a half minute",
      "timer a quarter minute",
      "quarter hour",
      "timer 0 minutes",
      "timer 181 minutes",
      "timer 999 minutes",
      "timer",
      "two",
    ]
    for phrase in rejected {
      guard case .unrecognized = parser.parse(phrase) else {
        return XCTFail("expected unrecognized: \(phrase)")
      }
    }
  }

  func testTimerRangeGuards() {
    assertParses("timer 0 minutes", .unrecognized(phrase: "timer 0 minutes"), "below 1 minute is not a timer")
    assertParses("timer 181 minutes", .unrecognized(phrase: "timer 181 minutes"), "above 180 minutes is not a timer")
    assertParses("timer 999 minutes", .unrecognized(phrase: "timer 999 minutes"))
    assertParses("timer", .unrecognized(phrase: "timer"), "a bare 'timer' names no duration")
    assertParses("two", .unrecognized(phrase: "two"), "a number alone is not a timer")
  }
  func testUnrecognizedPhrasesChangeNothing() {
    let table = [
      "what can I do with fennel",
      "how long do I boil an egg",
      "convert this to cups",
      "start a soup",
    ]
    for phrase in table {
      guard case .unrecognized = parser.parse(phrase) else {
        return XCTFail("expected unrecognized: \(phrase)")
      }
    }
  }
}
