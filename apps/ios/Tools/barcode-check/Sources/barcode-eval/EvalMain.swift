import BarcodeEvalSupport
import Foundation

/// Reproducible offline evaluation: drives every committed fixture GTIN through the
/// FLBarcode pipeline and prints a denominator-bound JSON report.
///
/// Usage: barcode-eval [fixture.jsonl] [catalog.json] [provenance.json]
/// Files default to the committed `Fixtures/` set. Set BARCODE_EVAL_OUTPUT=<path> to
/// also write the report JSON there.
@main
struct BarcodeEvalMain {
  static func main() async {
    let arguments = CommandLine.arguments
    let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let packageRoot =
      sourceDir
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtures = packageRoot.appendingPathComponent("Fixtures")

    let fixturePath =
      arguments.count > 1
      ? arguments[1]
      : fixtures.appendingPathComponent("off_products.jsonl").path
    let catalogPath =
      arguments.count > 2
      ? arguments[2]
      : fixtures.appendingPathComponent("eval-catalog.json").path
    let provenancePath =
      arguments.count > 3
      ? arguments[3]
      : fixtures.appendingPathComponent("PROVENANCE.json").path

    do {
      let records = try loadRecords(path: fixturePath)
      let catalogItems = try loadJSON([EvalCatalogItem].self, path: catalogPath)
      let provenance = try loadJSON(EvalProvenance.self, path: provenancePath)

      let counts = try await runEvaluation(
        records: records,
        catalogItems: catalogItems,
        provenance: provenance)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let payload = try encoder.encode(counts)
      print(String(decoding: payload, as: UTF8.self))

      if let outputPath = ProcessInfo.processInfo.environment["BARCODE_EVAL_OUTPUT"] {
        try payload.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      }
    } catch {
      FileHandle.standardError.write(Data("barcode-eval failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func loadRecords(path: String) throws -> [OFFFixtureRecord] {
    let raw = try String(contentsOfFile: path, encoding: .utf8)
    var records: [OFFFixtureRecord] = []
    for line in raw.split(separator: "\n")
    where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      records.append(try JSONDecoder().decode(OFFFixtureRecord.self, from: Data(line.utf8)))
    }
    return records
  }

  private static func loadJSON<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(try Data(contentsOf: URL(fileURLWithPath: path))))
  }
}
