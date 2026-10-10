import Foundation

// MARK: - Canonical JSON
//
// Byte-reproducible output: fixed types (integers/strings/bools only where
// digestable), sorted keys, no floats in digestable content, no wall-clock
// timestamps. Arrays keep insertion order (deterministic by construction).

public indirect enum JSON {
  case int(Int64)
  case string(String)
  case bool(Bool)
  case null
  case array([JSON])
  case object([(String, JSON)])  // ordered; writer sorts keys on output

  /// Convenience for the digest contract: compact, sorted-key rendering.
  public var render: String { CanonicalJSON.digestInput(self) }
}

enum CanonicalJSON {
  /// Renders with sorted keys, 2-space indent, and a trailing newline.
  static func render(_ value: JSON) -> String {
    var out = ""
    write(value, indent: 0, to: &out)
    return out
  }

  /// Compact, sorted-key form — the digest input.
  static func digestInput(_ value: JSON) -> String {
    var out = ""
    writeCompact(value, to: &out)
    return out
  }

  private static func write(_ value: JSON, indent: Int, to out: inout String) {
    switch value {
    case .int(let v):
      out += String(v)
    case .string(let v):
      out += escaped(v)
    case .bool(let v):
      out += v ? "true" : "false"
    case .null:
      out += "null"
    case .array(let items):
      if items.isEmpty {
        out += "[]"
        return
      }
      out += "[\n"
      for (index, item) in items.enumerated() {
        out += String(repeating: " ", count: (indent + 1) * 2)
        write(item, indent: indent + 1, to: &out)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent * 2) + "]"
    case .object(let pairs):
      if pairs.isEmpty {
        out += "{}"
        return
      }
      out += "{\n"
      let sorted = pairs.sorted { $0.0 < $1.0 }
      for (index, pair) in sorted.enumerated() {
        out += String(repeating: " ", count: (indent + 1) * 2)
        out += escaped(pair.0) + ": "
        write(pair.1, indent: indent + 1, to: &out)
        out += index == sorted.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent * 2) + "}"
    }
  }

  private static func writeCompact(_ value: JSON, to out: inout String) {
    switch value {
    case .int(let v):
      out += String(v)
    case .string(let v):
      out += escaped(v)
    case .bool(let v):
      out += v ? "true" : "false"
    case .null:
      out += "null"
    case .array(let items):
      out += "["
      for (index, item) in items.enumerated() {
        if index > 0 { out += "," }
        writeCompact(item, to: &out)
      }
      out += "]"
    case .object(let pairs):
      out += "{"
      for (index, pair) in pairs.sorted(by: { $0.0 < $1.0 }).enumerated() {
        if index > 0 { out += "," }
        out += escaped(pair.0) + ":"
        writeCompact(pair.1, to: &out)
      }
      out += "}"
    }
  }

  static func escaped(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}

// MARK: - JSON parsing
//
// Minimal recursive-descent parser for the report's own dialect: integers,
// strings, bools, null, arrays, objects. Floats are rejected outright — the
// digest contract forbids them, so a float anywhere means the body was
// hand-edited. Used by ReportVerifier to recompute summaries from the frozen
// measurements embedded in the report.

extension JSON {
  static func parse(_ text: String) throws -> JSON {
    var parser = JSONParser(Array(text.unicodeScalars))
    let value = try parser.parseValue()
    parser.skipWhitespace()
    guard parser.isAtEnd else {
      throw ReportVerifier.Failure(reason: "trailing content after JSON value")
    }
    return value
  }
}

private struct JSONParser {
  let scalars: [Unicode.Scalar]
  var index = 0

  init(_ scalars: [Unicode.Scalar]) {
    self.scalars = scalars
  }

  var isAtEnd: Bool { index >= scalars.count }

  mutating func skipWhitespace() {
    while index < scalars.count, scalars[index] == " " || scalars[index] == "\n"
      || scalars[index] == "\t" || scalars[index] == "\r"
    {
      index += 1
    }
  }

  mutating func expect(_ scalar: Unicode.Scalar) throws {
    skipWhitespace()
    guard index < scalars.count, scalars[index] == scalar else {
      throw ReportVerifier.Failure(reason: "expected '\(scalar)' at offset \(index)")
    }
    index += 1
  }

  mutating func parseValue() throws -> JSON {
    skipWhitespace()
    guard index < scalars.count else {
      throw ReportVerifier.Failure(reason: "unexpected end of JSON")
    }
    switch scalars[index] {
    case "{": return try parseObject()
    case "[": return try parseArray()
    case "\"": return .string(try parseString())
    case "t": return try parseLiteral("true", .bool(true))
    case "f": return try parseLiteral("false", .bool(false))
    case "n": return try parseLiteral("null", .null)
    case "-", "0"..."9": return try parseNumber()
    default:
      throw ReportVerifier.Failure(reason: "unexpected character at offset \(index)")
    }
  }

  mutating func parseLiteral(_ literal: String, _ value: JSON) throws -> JSON {
    let scalars = Array(literal.unicodeScalars)
    guard index + scalars.count <= self.scalars.count,
      Array(self.scalars[index..<index + scalars.count]) == scalars
    else {
      throw ReportVerifier.Failure(reason: "invalid literal at offset \(index)")
    }
    index += scalars.count
    return value
  }

  mutating func parseNumber() throws -> JSON {
    let start = index
    if scalars[index] == "-" { index += 1 }
    var digits = 0
    while index < scalars.count, scalars[index] >= "0", scalars[index] <= "9" {
      index += 1
      digits += 1
    }
    guard digits > 0 else {
      throw ReportVerifier.Failure(reason: "invalid number at offset \(start)")
    }
    if index < scalars.count, scalars[index] == "." || scalars[index] == "e"
      || scalars[index] == "E"
    {
      throw ReportVerifier.Failure(reason: "float in digestable content at offset \(start)")
    }
    let text = String(String.UnicodeScalarView(scalars[start..<index]))
    guard let value = Int64(text) else {
      throw ReportVerifier.Failure(reason: "number out of range at offset \(start)")
    }
    return .int(value)
  }

  mutating func parseString() throws -> String {
    index += 1  // opening quote
    var out = String.UnicodeScalarView()
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\"" {
        index += 1
        return String(out)
      }
      if scalar == "\\" {
        index += 1
        guard index < scalars.count else { break }
        switch scalars[index] {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "/": out.append("/")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "u":
          guard index + 4 < scalars.count,
            let code = UInt32(
              String(String.UnicodeScalarView(scalars[(index + 1)...(index + 4)])), radix: 16),
            let scalar = Unicode.Scalar(code)
          else {
            throw ReportVerifier.Failure(reason: "invalid \\u escape at offset \(index)")
          }
          out.append(scalar)
          index += 4
        default:
          throw ReportVerifier.Failure(reason: "invalid escape at offset \(index)")
        }
        index += 1
        continue
      }
      out.append(scalar)
      index += 1
    }
    throw ReportVerifier.Failure(reason: "unterminated string")
  }

  mutating func parseArray() throws -> JSON {
    index += 1  // [
    var items: [JSON] = []
    skipWhitespace()
    if index < scalars.count, scalars[index] == "]" {
      index += 1
      return .array(items)
    }
    while true {
      items.append(try parseValue())
      skipWhitespace()
      guard index < scalars.count else {
        throw ReportVerifier.Failure(reason: "unterminated array")
      }
      if scalars[index] == "," {
        index += 1
        continue
      }
      if scalars[index] == "]" {
        index += 1
        return .array(items)
      }
      throw ReportVerifier.Failure(reason: "expected ',' or ']' at offset \(index)")
    }
  }

  mutating func parseObject() throws -> JSON {
    index += 1  // {
    var pairs: [(String, JSON)] = []
    skipWhitespace()
    if index < scalars.count, scalars[index] == "}" {
      index += 1
      return .object(pairs)
    }
    while true {
      skipWhitespace()
      guard index < scalars.count, scalars[index] == "\"" else {
        throw ReportVerifier.Failure(reason: "expected object key at offset \(index)")
      }
      let key = try parseString()
      try expect(":")
      let value = try parseValue()
      pairs.append((key, value))
      skipWhitespace()
      guard index < scalars.count else {
        throw ReportVerifier.Failure(reason: "unterminated object")
      }
      if scalars[index] == "," {
        index += 1
        continue
      }
      if scalars[index] == "}" {
        index += 1
        return .object(pairs)
      }
      throw ReportVerifier.Failure(reason: "expected ',' or '}' at offset \(index)")
    }
  }
}

// MARK: - SHA-256
//
// Straightforward reference implementation — no external dependency, no
// platform variance.

struct SHA256 {
  static func digest(_ input: String) -> [UInt8] {
    digest(Array(input.utf8))
  }

  static func hex(_ input: String) -> String {
    digest(input).map { String(format: "%02x", $0) }.joined()
  }

  static func digest(_ bytes: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [
      0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
      0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    var message = bytes
    let bitLength = UInt64(bytes.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 {
      message.append(0)
    }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var w = [UInt32](repeating: 0, count: 64)
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      for i in 0..<16 {
        let base = chunkStart + i * 4
        w[i] =
          UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16
          | UInt32(message[base + 2]) << 8 | UInt32(message[base + 3])
      }
      for i in 16..<64 {
        let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
        let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] &+ s1 &+ w[i - 7] &+ s0
      }
      var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
      for i in 0..<64 {
        let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
        let ch = (e & f) ^ (~e & g)
        let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
        let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = s0 &+ maj
        hh = g; g = f; f = e; e = d &+ temp1
        d = c; c = b; b = a; a = temp1 &+ temp2
      }
      h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
      h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.flatMap { [
      UInt8(($0 >> 24) & 0xff), UInt8(($0 >> 16) & 0xff),
      UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff),
    ] }
  }

  private static let k: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]

  private static func rotateRight(_ value: UInt32, _ by: UInt32) -> UInt32 {
    (value >> by) | (value << (32 - by))
  }
}
