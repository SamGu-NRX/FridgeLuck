import Foundation
import LabelNumbersReplay

// Usage: label-numbers-replay [--predictions <out.jsonl>] [path-to-labels.jsonl]
// Default: prints the deterministic replay report (JSON) to stdout.
// --predictions: writes raw per-record parser outputs as JSONL to <out.jsonl>
//                (or stdout when <out.jsonl> is "-") instead of the report.
let args = CommandLine.arguments
let predictionsOut = args.firstIndex(of: "--predictions").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let positional = args.dropFirst().filter { $0 != "--predictions" && $0 != predictionsOut }
let corpusPath = positional.count > 0
    ? positional[0]
    : URL(fileURLWithPath: #filePath)  // Sources/label-numbers-replay/main.swift
        .deletingLastPathComponent()   // Sources/label-numbers-replay
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // SwiftReplay
        .deletingLastPathComponent()   // label-numbers-eval
        .appendingPathComponent("corpus/labels.jsonl")
        .path

do {
    let records = try CorpusReplay.loadCorpus(path: URL(fileURLWithPath: corpusPath))
    if let out = predictionsOut {
        let jsonl = try CorpusReplay.predictionsJSONL(CorpusReplay.predictions(records: records))
        if out == "-" {
            print(jsonl, terminator: "")
        } else {
            try jsonl.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        }
    } else {
        let report = CorpusReplay.run(records: records)
        print(try CorpusReplay.reportJSON(report))
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
