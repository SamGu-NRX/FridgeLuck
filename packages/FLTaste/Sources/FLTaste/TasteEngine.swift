import Foundation

/// The taste engine: the Part 1 surface the simulator (Part 2) and, later,
/// the app code against. Owns the append-only event log, the folded state,
/// and deterministic snapshots.
///
/// `TasteEngine` is a value type. Ingest re-folds the whole log so the
/// invariant `state == Fold.apply(events)` holds after every call (tested);
/// batch ingest refolds once.
public struct TasteEngine: Sendable {
    public let catalog: RecipeCatalog
    public let extractor: FeatureExtractor
    public private(set) var config: TasteConfig
    /// Append-only in ingest order. Snapshot serialization sorts canonically.
    public private(set) var events: [TasteEvent]
    public private(set) var state: EngineState
    /// Behavioral posteriors per eater, refolded with the state after every
    /// ingest (same total-cost model as the state refold).
    public private(set) var model: TasteModel

    public init(catalog: RecipeCatalog, config: TasteConfig = .standard) {
        self.catalog = catalog
        self.extractor = FeatureExtractor(catalog: catalog)
        self.config = config
        self.events = []
        self.state = EngineState()
        self.model = TasteModel(
            events: [], extractor: FeatureExtractor(catalog: catalog), catalog: catalog,
            config: config)
    }

    /// Restores from canonical snapshot bytes: parses, migrates forward,
    /// checks the feature-space version, re-folds. Throws on unknown format
    /// versions (fail closed).
    public init(snapshotJSON: String, catalog: RecipeCatalog) throws {
        let parsed = try JSONParser.parse(snapshotJSON)
        let (events, config) = try SnapshotCodec.decode(
            parsed, featureSpaceVersion: FeatureExtractor(catalog: catalog).version)
        self.catalog = catalog
        self.extractor = FeatureExtractor(catalog: catalog)
        self.config = config
        self.events = events
        self.state = Fold.apply(events)
        self.model = TasteModel(
            events: events, extractor: self.extractor, catalog: catalog, config: config)
    }

    // MARK: Ingest

    /// Ingests one event. Replaying a duplicate event ID is a no-op (the
    /// duplicate is not appended). A correction whose target is not (yet)
    /// known is recorded as a diagnostic and has no effect.
    public mutating func ingest(_ event: TasteEvent) {
        ingest([event])
    }

    /// Ingests a batch with a single refold. Order inside the batch does not
    /// matter: the fold canonicalizes by (timestamp, id).
    public mutating func ingest(_ newEvents: [TasteEvent]) {
        let fresh = newEvents.filter { !state.seenEventIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        events.append(contentsOf: fresh)
        state = Fold.apply(events)
        model = TasteModel(
            events: events, extractor: extractor, catalog: catalog, config: config)
    }

    // MARK: Ranking

    /// Ranks feasible candidates (SPEC 3.3 contract). Hard restrictions are
    /// applied before the model sees any candidate. Deterministic given the
    /// seeded RNG; `context.now` defaults to the log's last event time.
    public func rank(_ input: RankInput, rng: inout SeededRNG) -> [RankedRecipe] {
        let ranker = Ranker(
            config: config, catalog: catalog, extractor: extractor, model: model, state: state)
        return ranker.rank(input, rng: &rng)
    }

    // MARK: Snapshots

    /// Canonical snapshot bytes. Identical logical state produces identical
    /// bytes (tested).
    public func snapshotJSON() throws -> String {
        CanonicalJSON.encode(SnapshotCodec.encode(events, config: config))
    }

    public var eventCount: Int { state.eventCount }
    public var seenEventIDs: Set<EventID> { state.seenEventIDs }
}
