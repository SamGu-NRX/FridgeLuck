import CatalogReplayCore
import Foundation

func arg(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name) else { return nil }
  let valueIndex = index + 1
  guard valueIndex < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[valueIndex]
}

guard let dbPath = arg("--db"), let probesPath = arg("--probes") else {
  FileHandle.standardError.write(
    Data("usage: CatalogResolverReplay --db <catalog.sqlite> --probes <probes.jsonl> [--out <jsonl>] [--meta <json>]\n".utf8)
  )
  exit(2)
}

let probes: [ProbeCase]
do {
  probes = try ReplayRunner.parseProbes(String(contentsOfFile: probesPath, encoding: .utf8))
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(2)
}

let (rows, meta) = try ReplayRunner.run(dbPath: dbPath, probes: probes)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func jsonLine<T: Encodable>(_ value: T) -> String {
  String(data: try! encoder.encode(value), encoding: .utf8)! + "\n"
}

var output = ""
for row in rows {
  output += jsonLine(row)
}

if let outPath = arg("--out") {
  try output.write(toFile: outPath, atomically: true, encoding: .utf8)
} else {
  print(output, terminator: "")
}

if let metaPath = arg("--meta") {
  try jsonLine(meta).write(toFile: metaPath, atomically: true, encoding: .utf8)
}

FileHandle.standardError.write(
  Data("replayed \(rows.count) probes over \(meta.catalogFile) (\(meta.catalogIngredientRows) ingredients, \(meta.catalogAliasRows) aliases)\n".utf8)
)
