import XCTest

/// Shared test helpers.
func makeTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FLKitchenKnowledgeTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
