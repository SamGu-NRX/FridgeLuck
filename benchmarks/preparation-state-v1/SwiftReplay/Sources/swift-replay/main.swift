import Foundation
import SwiftReplayProduction

// Reads probe records on stdin: {"probe_id": "...", "text": "..."} per line.
// Emits one JSON line per probe: {"probe_id", "resolved_id" (Int64?), "matched_token"}.
// This replays the production curated-lexicon path (IngredientLexicon) exactly as
// shipped; the catalog-resolution path needs GRDB and the app database and is
// replayed in Python (run.py production_replay) until a macOS harness is wired up.

struct Probe: Decodable {
    let probe_id: String
    let text: String
}

func emit(_ dict: [String: String?]) {
    let payload = dict.map { key, value in
        let v = value.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"
        return "\"\(key)\": \(v)"
    }.joined(separator: ", ")
    print("{\(payload)}")
}

func main() {
    while let line = readLine() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard
            let data = line.data(using: .utf8),
            let probe = try? JSONDecoder().decode(Probe.self, from: data)
        else {
            emit(["probe_id": nil, "error": "undecodable_line"])
            continue
        }
        let match = IngredientLexicon.resolveFromTextDetailed(probe.text)
        emit([
            "probe_id": probe.probe_id,
            "resolved_id": match.map { String($0.ingredientId) },
            "matched_token": match?.matchedToken,
        ])
    }
}

main()
