import Foundation

/// A JSON value tree with a canonical byte encoding.
///
/// FLTaste owns serialization end to end because byte-identical snapshots are
/// a test guarantee. `JSONEncoder` does not promise a canonical field order or
/// a stable number format across platforms, so this module defines both:
/// object keys are sorted, there is no insignificant whitespace, and doubles
/// use a fixed round-trip-precision format.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNumber: Bool {
        switch self {
        case .int, .double: return true
        default: return false
        }
    }

    /// Object field access; nil on every other case and for missing keys.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }
}

public enum CanonicalJSONError: Error, Equatable {
    case parseFailed(offset: Int, reason: String)
    case nonFiniteNumber(Double)
}

// MARK: - Writing

public enum CanonicalJSON {
    /// Encodes to canonical bytes: sorted object keys, no whitespace,
    /// doubles in "%.17g" form (with a forced ".0" when the result would
    /// otherwise read as an integer).
    public static func encode(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += canonicalDouble(d)
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (i, key) in fields.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(fields[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func canonicalDouble(_ d: Double) -> String {
        // NaN and infinity have no JSON form; a model that produced one is
        // already broken, so fail loudly here rather than emit corrupt bytes.
        guard d.isFinite else { fatalError("CanonicalJSON: non-finite double \(d)") }
        let normalized = d == 0 ? 0.0 : d  // collapse -0.0
        let text = String(format: "%.17g", normalized)
        if text.contains(".") || text.contains("e") || text.contains("E") {
            return text
        }
        return text + ".0"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
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
        out += "\""
    }
}

// MARK: - Parsing

/// A strict recursive-descent JSON parser. Numbers without a fraction or
/// exponent become `.int` (Int64 range), everything else numeric becomes
/// `.double`. This split makes encoded/decoded bytes agree by construction.
public enum JSONParser {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Scanner(text: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw CanonicalJSONError.parseFailed(offset: parser.offset, reason: "trailing content")
        }
        return value
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var offset = 0

        init(text: [Unicode.Scalar]) {
            self.scalars = text
        }

        var isAtEnd: Bool { offset >= scalars.count }

        var offsetValue: Int { offset }

        mutating func skipWhitespace() {
            while offset < scalars.count, scalars[offset] == " " || scalars[offset] == "\t"
                || scalars[offset] == "\n" || scalars[offset] == "\r"
            {
                offset += 1
            }
        }

        func peek() -> Unicode.Scalar? {
            offset < scalars.count ? scalars[offset] : nil
        }

        mutating func expect(_ s: Unicode.Scalar) throws {
            guard peek() == s else {
                throw CanonicalJSONError.parseFailed(offset: offset, reason: "expected '\(s)'")
            }
            offset += 1
        }

        mutating func parseValue() throws -> JSONValue {
            guard let c = peek() else {
                throw CanonicalJSONError.parseFailed(offset: offset, reason: "unexpected end")
            }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try parseLiteral("true"); return .bool(true)
            case "f": try parseLiteral("false"); return .bool(false)
            case "n": try parseLiteral("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseLiteral(_ literal: String) throws {
            for expected in literal.unicodeScalars {
                guard peek() == expected else {
                    throw CanonicalJSONError.parseFailed(offset: offset, reason: "bad literal")
                }
                offset += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            try expect("{")
            var fields: [String: JSONValue] = [:]
            skipWhitespace()
            if peek() == "}" {
                offset += 1
                return .object(fields)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                fields[key] = try parseValue()
                skipWhitespace()
                if peek() == "," {
                    offset += 1
                    continue
                }
                try expect("}")
                return .object(fields)
            }
        }

        mutating func parseArray() throws -> JSONValue {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if peek() == "]" {
                offset += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                if peek() == "," {
                    offset += 1
                    continue
                }
                try expect("]")
                return .array(items)
            }
        }

        mutating func parseString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek() else {
                    throw CanonicalJSONError.parseFailed(offset: offset, reason: "unterminated string")
                }
                offset += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard let esc = peek() else {
                        throw CanonicalJSONError.parseFailed(offset: offset, reason: "bad escape")
                    }
                    offset += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        let hex = try parseHex4()
                        if (0xD800...0xDBFF).contains(hex.first),
                           scalars.count > offset + 1, peek() == "\\", scalars[offset + 1] == "u"
                        {
                            offset += 2
                            let low = try parseHex4()
                            let combined = 0x10000 + ((hex.first - 0xD800) << 10)
                                + (low.first - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else {
                                throw CanonicalJSONError.parseFailed(
                                    offset: offset, reason: "bad surrogate pair")
                            }
                            out.append(scalar)
                        } else if let scalar = Unicode.Scalar(hex.first) {
                            out.append(scalar)
                        } else {
                            throw CanonicalJSONError.parseFailed(
                                offset: offset, reason: "bad unicode escape")
                        }
                    default:
                        throw CanonicalJSONError.parseFailed(offset: offset, reason: "bad escape")
                    }
                } else {
                    out.append(c)
                }
            }
        }

        mutating func parseHex4() throws -> (first: UInt32, offset: Int) {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = peek(), let digit = Self.hexDigitValue(c) else {
                    throw CanonicalJSONError.parseFailed(offset: offset, reason: "bad hex")
                }
                value = value << 4 | UInt32(digit)
                offset += 1
            }
            return (value, offset)
        }

        private static func hexDigitValue(_ scalar: Unicode.Scalar) -> Int? {
            switch scalar {
            case "0"..."9": return Int(scalar.value - 48)
            case "a"..."f": return Int(scalar.value - 87)
            case "A"..."F": return Int(scalar.value - 55)
            default: return nil
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = offset
            var isDouble = false
            while let c = peek(),
                (c >= "0" && c <= "9") || c == "-" || c == "+" || c == "." || c == "e" || c == "E"
            {
                if c == "." || c == "e" || c == "E" { isDouble = true }
                offset += 1
            }
            let text = String(String.UnicodeScalarView(scalars[start..<offset]))
            guard !text.isEmpty else {
                throw CanonicalJSONError.parseFailed(offset: start, reason: "expected number")
            }
            if !isDouble {
                if let i = Int64(text) { return .int(i) }
            }
            guard let d = Double(text), d.isFinite else {
                throw CanonicalJSONError.parseFailed(offset: start, reason: "bad number \(text)")
            }
            return .double(d)
        }
    }
}
