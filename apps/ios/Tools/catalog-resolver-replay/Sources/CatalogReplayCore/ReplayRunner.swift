import Foundation
import GRDB

/// One replay row: the same probe input answered by the REAL production
/// resolver (mirrored byte-identically) running on GRDB over the pinned
/// catalog. Field names mirror the Python catalog port's surface so the
/// differential diff is field-by-field.
public struct ReplayRow: Encodable {
  public var kind: String
  public var input: String
  public var resolveExact: String?
  public var resolveAllowPrefix: String?
  public var resolveFromText: String?
  public var displayNameExact: String?
  public var displayNameAllowPrefix: String?
  public var displayNameFromText: String?

  public init(
    kind: String, input: String, resolveExact: String?, resolveAllowPrefix: String?,
    resolveFromText: String?, displayNameExact: String?, displayNameAllowPrefix: String?,
    displayNameFromText: String?
  ) {
    self.kind = kind
    self.input = input
    self.resolveExact = resolveExact
    self.resolveAllowPrefix = resolveAllowPrefix
    self.resolveFromText = resolveFromText
    self.displayNameExact = displayNameExact
    self.displayNameAllowPrefix = displayNameAllowPrefix
    self.displayNameFromText = displayNameFromText
  }

  private enum Keys: String, CodingKey {
    case kind, input, resolveExact, resolveAllowPrefix, resolveFromText
    case displayNameExact, displayNameAllowPrefix, displayNameFromText
  }

  // encode nil explicitly as null: every committed row keeps the same schema
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(input, forKey: .input)
    try container.encode(resolveExact, forKey: .resolveExact)
    try container.encode(resolveAllowPrefix, forKey: .resolveAllowPrefix)
    try container.encode(resolveFromText, forKey: .resolveFromText)
    try container.encode(displayNameExact, forKey: .displayNameExact)
    try container.encode(displayNameAllowPrefix, forKey: .displayNameAllowPrefix)
    try container.encode(displayNameFromText, forKey: .displayNameFromText)
  }
}

public struct ReplayMeta: Encodable {
  public var catalogFile: String
  public var catalogIngredientRows: Int
  public var catalogAliasRows: Int
  public var probes: Int
  public var sourceManifest: [String: String]
  public var tool: String

  public init(
    catalogFile: String, catalogIngredientRows: Int, catalogAliasRows: Int, probes: Int,
    sourceManifest: [String: String], tool: String
  ) {
    self.catalogFile = catalogFile
    self.catalogIngredientRows = catalogIngredientRows
    self.catalogAliasRows = catalogAliasRows
    self.probes = probes
    self.sourceManifest = sourceManifest
    self.tool = tool
  }
}

public struct ProbeCase {
  public let kind: String
  public let input: String
}

public enum ReplayError: Error {
  case missingArgument(String)
  case badJSONL(String)
}

public enum ReplayRunner {
  public static func parseProbes(_ text: String) throws -> [ProbeCase] {
    var probes: [ProbeCase] = []
    for (lineNumber, line) in text.split(separator: "\n").enumerated() {
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      guard let data = line.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = obj["kind"] as? String,
            let input = obj["input"] as? String
      else {
        throw ReplayError.badJSONL("line \(lineNumber + 1): \(line.prefix(60))")
      }
      probes.append(ProbeCase(kind: kind, input: input))
    }
    return probes
  }

  public static func run(dbPath: String, probes: [ProbeCase]) throws -> (rows: [ReplayRow], meta: ReplayMeta) {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: dbPath, configuration: config)

    let (ingredientRows, aliasRows): (Int, Int) = try queue.read { db in
      let ingredients = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients") ?? 0
      let aliases = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredient_aliases") ?? 0
      return (ingredients, aliases)
    }

    // The production resolver, mirrored byte-identically from the app sources.
    let resolver = IngredientCatalogResolver(db: queue)

    var rows: [ReplayRow] = []
    for probe in probes {
      let exact = resolver.resolve(probe.input, matching: .exact)
      let allowPrefix = resolver.resolve(probe.input, matching: .allowPrefix)
      let fromText = resolver.resolveFromText(probe.input)
      rows.append(
        ReplayRow(
          kind: probe.kind,
          input: probe.input,
          resolveExact: exact.map(String.init),
          resolveAllowPrefix: allowPrefix.map(String.init),
          resolveFromText: fromText.map(String.init),
          displayNameExact: exact.flatMap { resolver.displayName(for: $0) },
          displayNameAllowPrefix: allowPrefix.flatMap { resolver.displayName(for: $0) },
          displayNameFromText: fromText.flatMap { resolver.displayName(for: $0) }
        )
      )
    }

    let meta = ReplayMeta(
      catalogFile: URL(fileURLWithPath: dbPath).lastPathComponent,
      catalogIngredientRows: ingredientRows,
      catalogAliasRows: aliasRows,
      probes: rows.count,
      sourceManifest: SourceManifest.sha256,
      tool: "catalog-resolver-replay"
    )
    return (rows, meta)
  }
}
