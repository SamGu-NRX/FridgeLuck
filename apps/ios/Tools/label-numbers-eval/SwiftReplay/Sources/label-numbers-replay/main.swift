import Foundation
import LabelNumbersReplay

// Usage: label-numbers-replay [path-to-labels.jsonl]
// Prints the deterministic replay report (JSON) to stdout.
let args = CommandLine.arguments
let corpusPath = args.count > 1
    ? args[1]
    : URL(fileURLWithPath: #filePath)  // Sources/label-numbers-replay/main.swift
        .deletingLastPathComponent()   // Sources/label-numbers-replay
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // SwiftReplay
        .deletingLastPathComponent()   // label-numbers-eval
        .appendingPathComponent("corpus/labels.jsonl")
        .path

do {
    let records = try CorpusReplay.loadCorpus(path: URL(fileURLWithPath: corpusPath))
    let report = CorpusReplay.run(records: records)
    print(try CorpusReplay.reportJSON(report))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
