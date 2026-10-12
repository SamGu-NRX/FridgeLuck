// FLScreens lint tests — the swappable-theme guarantee, enforced.
//
// Sam's round decision on PR #95: Direction H is provisional and the
// morning pick replaces it BY SWAPPING THEME TOKENS. That only holds if
// screen sources never hard-code a visual value. This test fails the Linux
// suite if any screen source in this package contains:
//
// - a hex colour literal (`#RRGGBB`, `#RRGGBBAA`, `#RGB`, or a
//   `0xRRGGBB`-style literal) — colours come from FLDesignTokens roles;
// - a font name (`"SF Pro"`, `"SF Mono"`, `"New York"`, custom-font
//   constructors) or any direct font construction — type comes from
//   `TypeRole` through `.flType`.
//
// The lint scans RAW source text, so gated-out SwiftUI sections are
// covered too — exactly the code Linux cannot type-check.

import XCTest

final class LintTests: XCTestCase {

    // MARK: Locating the sources (from #filePath — no cwd assumptions)

    private var packageRoot: URL {
        // This file lives at <root>/Tests/FLScreensLintTests/LintTests.swift.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var screenSources: [(path: String, text: String)] {
        let sourcesDir = packageRoot.appendingPathComponent("Sources")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sourcesDir.path)) ?? []
        var result: [(String, String)] = []
        for targetDir in files {
            let targetURL = sourcesDir.appendingPathComponent(targetDir)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: targetURL.path) else { continue }
            for name in names where name.hasSuffix(".swift") {
                let fileURL = targetURL.appendingPathComponent(name)
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                result.append(("\(targetDir)/\(name)", text))
            }
        }
        return result
    }

    // MARK: Patterns

    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA` — with word boundaries so `#if`,
    /// `#filePath` and `#selector` never match.
    private static let hexColour = try! NSRegularExpression(
        pattern: "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b"
    )
    /// `0x`-style colour literals (six or more hex digits — the form
    /// `ColorToken(hex:)` takes, which screens must never need).
    private static let hexNumberLiteral = try! NSRegularExpression(
        pattern: "0x[0-9a-fA-F]{6,8}\\b"
    )
    /// Font names the system's type must never be hard-coded as.
    private static let fontNames: [String] = ["SF Pro", "SF Mono", "New York"]
    /// Direct font construction: type roles are the only type path.
    private static let fontConstruction = try! NSRegularExpression(
        pattern: "(?:\\bFont\\s*\\(|\\.font\\s*\\(|\\.fontDesign|custom\\s*\\()"
    )

    private func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: The lint

    func testNoHexColourLiteralsInScreenSources() throws {
        var findings: [String] = []
        for (path, text) in screenSources {
            for match in matches(Self.hexColour, in: text) {
                findings.append("\(path): hex colour literal \(match)")
            }
            for match in matches(Self.hexNumberLiteral, in: text) {
                findings.append("\(path): hex number literal \(match)")
            }
        }
        XCTAssertTrue(findings.isEmpty, "Hard-coded colours defeat the theme swap:\n" + findings.joined(separator: "\n"))
    }

    func testNoFontNamesOrFontConstructionInScreenSources() throws {
        var findings: [String] = []
        for (path, text) in screenSources {
            for name in Self.fontNames {
                if text.contains(name) {
                    findings.append("\(path): font name \"\(name)\"")
                }
            }
            for match in matches(Self.fontConstruction, in: text) {
                findings.append("\(path): direct font construction \(match.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(findings.isEmpty, "Hard-coded type defeats the theme swap:\n" + findings.joined(separator: "\n"))
    }

    func testLintCoversEveryTargetAndIsNotEmpty() throws {
        // The lint is only as good as its file discovery: it must see
        // sources from all three targets, and each must be non-trivial.
        let sources = screenSources
        let targets = Set(sources.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
        for target in ["FLScreenSupport", "FLTonight", "FLKitchen"] {
            XCTAssertTrue(targets.contains(target), "the lint found no sources for \(target)")
        }
        XCTAssertGreaterThanOrEqual(sources.count, 5, "the lint found suspiciously few files")
        for (path, text) in sources {
            XCTAssertGreaterThan(
                text.count, 50,
                "\(path) looks empty — the lint would silently pass over it"
            )
        }
    }
}
