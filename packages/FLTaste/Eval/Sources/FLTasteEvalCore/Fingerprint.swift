import Foundation

// Hash-bound resume: a checkpoint may only be resumed when the code,
// configuration, and corpus that would accept it are the ones that
// produced it. Everything here is pure Swift so the hashes are identical
// on every host and testable against published vectors.

/// FIPS 180-4 SHA-256, pure Swift: identical bytes on every platform, no
/// dependency on host crypto availability.
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// 32-byte digest of the input.
    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8

        // Padding: 0x80, zeros, 64-bit big-endian length.
        var message = bytes
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let base = blockStart + i * 4
                w[i] =
                    (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a, b, c, d, e, f, g, hh: UInt32
            (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap { [$0 >> 24, ($0 >> 16) & 0xff, ($0 >> 8) & 0xff, $0 & 0xff].map(UInt8.init) }
    }

    /// Lowercase hex digest.
    public static func hex(_ string: String) -> String {
        digest(Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex digest of a file's bytes (nil when unreadable).
    public static func hex(fileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return digest(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

/// Bumped whenever metric semantics or the checkpoint schema change:
/// stale checkpoints (older semantics) must never silently resume.
/// v2: one recovery observation per shift, full-universe NDCG ideal,
/// independent fail-closed restriction violations.
/// v3: never-suggest cutoff fix — the mute emitted by a session applies
/// from the NEXT session on (Sim ranked the slate before the preference
/// existed); counting it same-session falsely flagged post-shift slates.
/// v4: mute enforcement aligned to the simulator's granularity — Sim
/// snapshots never-suggest into its week-start FeasibilityFilter, so a
/// mid-week mute cannot reach the ranker-visible candidate set until the
/// next week boundary regardless of arm behavior (RankInput has no mute
/// surface). A mute emitted in week w counts against slates in weeks > w.
/// v3's next-session clock flagged slates Sim itself could not have
/// prevented (observed: 2 in random, 3 in rule-port, all in the two-eater
/// regime of a 7-household probe).
public let metricsVersion = "4"

/// The resume fingerprint stamped into every checkpoint and compared on
/// resume: a checkpoint with any mismatched field is stale and rejected.
public struct ResumeFingerprint: Codable, Equatable, Sendable {
    public var configHash: String
    public var corpusHash: String
    public var codeHash: String
    public var metricsVersion: String

    public init(configHash: String, corpusHash: String, codeHash: String, metricsVersion: String) {
        self.configHash = configHash
        self.corpusHash = corpusHash
        self.codeHash = codeHash
        self.metricsVersion = metricsVersion
    }
}

/// Canonical, order-independent config summary for hashing: only the fields
/// that change results (workers is scheduling, not semantics). Sorted seeds
/// and sorted arm ids make set-equal configs hash equal.
public func canonicalConfigString(
    householdsPerSeed: Int, weeks: Int, bootstrapResamples: Int,
    seeds: [UInt64], armIDs: [String]?
) -> String {
    let seedPart = seeds.sorted().map { String($0) }.joined(separator: ",")
    let armPart = (armIDs?.sorted() ?? ["all"]).joined(separator: ",")
    return "v1|households=\(householdsPerSeed)|weeks=\(weeks)|boot=\(bootstrapResamples)"
        + "|arms=\(armPart)|seeds=\(seedPart)"
}

/// Code identity: the producing git SHA plus a hash over the dirty working
/// tree (path + content hash per file), so uncommitted code changes can
/// never be confused with committed ones. Fail-soft: unknown git state
/// yields the literal "unknown", which never matches a real fingerprint
/// (resume then recomputes — the safe direction).
public func codeVersionHash() -> String {
    func git(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    guard let sha = git(["rev-parse", "HEAD"]), !sha.isEmpty else { return "unknown" }
    guard let status = git(["status", "--porcelain"]) else { return "unknown" }
    var lines: [String] = []
    for entry in status.split(separator: "\n") {
        // Porcelain: "XY <path>" (rename entries "XY orig -> dest" use dest).
        let raw = entry.dropFirst(3)
        let path = raw.contains(" -> ") ? raw.components(separatedBy: " -> ")[1] : String(raw)
        guard !path.isEmpty else { continue }
        if path.hasSuffix("\"") && path.hasPrefix("\"") {
            continue  // quoted (unusual) paths: treated as changed code below
        }
        guard let hash = SHA256.hex(fileAt: path) else { return "unknown" }
        lines.append("\(path):\(hash)")
    }
    if lines.count > 500 { return "unknown" }  // pathological tree: refuse to fingerprint
    lines.sort()
    return SHA256.hex(sha + "\n" + lines.joined(separator: "\n"))
}

/// Pure acceptance check: a checkpoint resumes only when every fingerprint
/// field matches the current run's identity. A missing fingerprint (schema
/// or code older than v2) is itself a mismatch.
public func checkpointAcceptable(saved: ResumeFingerprint?, current: ResumeFingerprint) -> Bool {
    saved == current
}
