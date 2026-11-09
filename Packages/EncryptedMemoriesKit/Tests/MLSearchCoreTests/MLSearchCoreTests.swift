import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

/// Tests index planning, progress, vector ranking, and store replay.
@Suite struct MLSearchCoreTests {
    private let descriptorV1 = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 4)
    private let descriptorV2 = MLModelDescriptor(identifier: "fixture-model", version: 2, embeddingDimension: 4)

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func record(
        _ id: String, _ descriptor: MLModelDescriptor, _ vector: [Float32], ts: Date = Date(timeIntervalSince1970: 1000)
    ) -> MLEmbeddingRecord {
        MLEmbeddingRecord(uid: uid(id), descriptor: descriptor, vector: ContiguousArray(vector), timestamp: ts)
    }

    @Test func assetUniversePublishesWholeLibrarySnapshots() {
        let universe = MLAssetUniverse(authoritative: [uid("a0")])
        let replacement = [uid("a1"), uid("a2")]

        #expect(universe.snapshot() == .authoritative([uid("a0")]))
        #expect(universe.publishAuthoritative(replacement))
        #expect(!universe.publishAuthoritative(replacement))
        #expect(universe.snapshot() == .authoritative(replacement))

        universe.beginHydration()
        #expect(universe.snapshot() == .hydrating)
    }

    @Test func assetUniversePreservesSourceScopeOrderAndAuthority() {
        let source = LibrarySource(
            id: SourceID("source"),
            capabilities: [.readThumbnail]
        )
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([source], using: sourceSetLease)
        let initialRefresh = graph.beginRefresh(source.id)!
        _ = graph.commit(
            [
                .complete(
                    PhotoItem(
                        uid: uid("b"),
                        captureTime: Date(timeIntervalSince1970: 1),
                        mediaType: "image/jpeg"
                    )
                ),
                .complete(
                    PhotoItem(
                        uid: uid("a"),
                        captureTime: Date(timeIntervalSince1970: 2),
                        mediaType: "image/jpeg"
                    )
                ),
            ],
            validationToken: nil,
            using: initialRefresh
        )
        let replacementRefresh = graph.beginRefresh(source.id)!
        let scope = graph.analysisDerivedDataScope()
        let universe = MLAssetUniverse(analysisScope: scope)

        #expect(universe.snapshot() == MLAssetInventorySnapshot(analysisScope: scope))

        let authoritative = graph.commit(
            [
                .complete(
                    PhotoItem(
                        uid: uid("a"),
                        captureTime: Date(timeIntervalSince1970: 2),
                        mediaType: "image/jpeg"
                    )
                )
            ],
            validationToken: nil,
            using: replacementRefresh
        )!.analysisScope
        #expect(universe.publish(authoritative))
        #expect(universe.snapshot() == MLAssetInventorySnapshot(analysisScope: authoritative))

        #expect(!universe.publish(scope))
        #expect(universe.snapshot() == MLAssetInventorySnapshot(analysisScope: authoritative))

        let otherGraph = LibrarySourceGraph()
        let otherSetLease = otherGraph.beginSourceSetRefresh()
        _ = otherGraph.commitSourceSet([source], using: otherSetLease)
        let otherRefresh = otherGraph.beginRefresh(source.id)!
        let otherEpoch = otherGraph.commit(
            [
                .complete(
                    PhotoItem(
                        uid: uid("other"),
                        captureTime: Date(timeIntervalSince1970: 3),
                        mediaType: "image/jpeg"
                    )
                )
            ],
            validationToken: nil,
            using: otherRefresh
        )!.analysisScope
        #expect(!universe.publish(otherEpoch))
        #expect(!universe.publishAuthoritative([uid("legacy")]))

        universe.invalidateSourceSession()
        #expect(universe.snapshot() == .hydrating)
        #expect(!universe.publish(authoritative))
        #expect(!universe.publishAuthoritative([uid("late-legacy")]))
        universe.resetSourceSession(to: otherEpoch.epoch)
        #expect(universe.publish(otherEpoch))
        #expect(universe.snapshot() == MLAssetInventorySnapshot(analysisScope: otherEpoch))
    }

    @Test func nonAuthoritativeScopeImmediatelyHidesExplicitlyRemovedSource() {
        let sourceA = LibrarySource(
            id: SourceID("source-a"),
            capabilities: [.readThumbnail]
        )
        let sourceB = LibrarySource(
            id: SourceID("source-b"),
            capabilities: [.readThumbnail]
        )
        let uidA = uid("a")
        let uidB = uid("b")
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([sourceA, sourceB], using: sourceSetLease)
        let refreshA = graph.beginRefresh(sourceA.id)!
        _ = graph.commit(
            [
                .complete(
                    PhotoItem(
                        uid: uidA,
                        captureTime: Date(timeIntervalSince1970: 1),
                        mediaType: "image/jpeg"
                    )
                )
            ],
            validationToken: nil,
            using: refreshA
        )
        let refreshB = graph.beginRefresh(sourceB.id)!
        _ = graph.commit(
            [
                .complete(
                    PhotoItem(
                        uid: uidB,
                        captureTime: Date(timeIntervalSince1970: 2),
                        mediaType: "image/jpeg"
                    )
                )
            ],
            validationToken: nil,
            using: refreshB
        )
        let initialScope = graph.analysisDerivedDataScope()
        let universe = MLAssetUniverse(analysisScope: initialScope)

        #expect(initialScope.isAuthoritative)
        #expect(initialScope.uids == [uidA, uidB])

        _ = graph.beginRefresh(sourceA.id)
        let removalScope = graph.removeSource(sourceB.id)!.analysisScope
        #expect(!removalScope.isAuthoritative)
        #expect(removalScope.uids == [uidA])
        #expect(universe.publish(removalScope))
        #expect(universe.snapshot() == MLAssetInventorySnapshot(analysisScope: removalScope))
    }

    @Test func alreadyIndexedAssetsAreNotPlannedAgain() throws {
        let store = InMemoryMLIndexStore()
        let assets = (0..<5).map { uid("a\($0)") }
        // Pre-index the first two.
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])

        let plan = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)

        #expect(plan.toIndex.map(\.nodeID).sorted() == ["a2", "a3", "a4"])
        #expect(plan.skippedAlreadyIndexed.count == 2)
        #expect(plan.skippedPermanentFailure.isEmpty)
        #expect(plan.totalAssets == 5)
        #expect(!plan.isComplete)
    }

    @Test func rePlanningAfterFullIndexIsComplete() throws {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        let plan = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        #expect(plan.toIndex.isEmpty)
        #expect(plan.isComplete)
    }

    @Test func plannerDeduplicatesHostAssetListWithoutChangingOrder() throws {
        let store = InMemoryMLIndexStore()
        let plan = try MLIndexPlanner.plan(
            allAssets: [uid("a0"), uid("a1"), uid("a0"), uid("a2"), uid("a1")],
            descriptor: descriptorV1,
            store: store
        )

        #expect(plan.toIndex.map(\.nodeID) == ["a0", "a1", "a2"])
        #expect(plan.totalAssets == 3)
    }

    @Test func modelVersionChangeCreatesNewEpoch() throws {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        // Fully indexed under v1.
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        // Under v2, everything must re-index despite v1 being complete.
        let planV2 = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV2, store: store)
        #expect(planV2.toIndex.count == 2)
        #expect(planV2.skippedAlreadyIndexed.isEmpty)
        // v1 epoch is untouched by v2 planning.
        #expect(store.count(for: descriptorV1) == 2)
        #expect(store.count(for: descriptorV2) == 0)
    }

    @Test func differentModelIdentifierIsIndependentEpoch() {
        let otherModel = MLModelDescriptor(identifier: "other-clip", version: 1, embeddingDimension: 4)
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        // Different identifier, same version to still a distinct epoch.
        #expect(!store.contains(uid: uid("a0"), descriptor: otherModel))
        #expect(store.contains(uid: uid("a0"), descriptor: descriptorV1))
    }

    @Test func permanentFailureDoesNotBlockOthers() throws {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        store.recordFailures([
            MLIndexFailureRecord(uid: uid("a1"), descriptor: descriptorV1, kind: .permanent, attempts: 1)
        ])
        let plan = try MLIndexPlanner.plan(
            allAssets: assets,
            descriptor: descriptorV1,
            store: store
        )
        #expect(plan.toIndex.map(\.nodeID).sorted() == ["a0", "a2"])
        #expect(plan.skippedPermanentFailure.count == 1)
        #expect(plan.skippedPermanentFailure.contains(uid("a1")))
    }

    @Test func incrementalReconciliationRemovesOnlyThePreviousAuthoritativeDelta() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("retained", descriptorV1, [1, 0, 0, 0]),
            record("removed", descriptorV1, [0, 1, 0, 0]),
            record("outside-baseline", descriptorV1, [0, 0, 1, 0]),
        ])
        store.recordFailures([
            MLIndexFailureRecord(
                uid: uid("failed-removed"),
                descriptor: descriptorV1,
                kind: .permanent,
                attempts: 1
            )
        ])
        let generation = store.generation(for: descriptorV1)

        #expect(
            store.reconcileTrackedUIDs(
                currentAuthoritativeUIDs: [uid("retained")],
                previousAuthoritativeUIDs: [
                    uid("retained"), uid("removed"), uid("removed"), uid("failed-removed"),
                ],
                descriptor: descriptorV1
            ))

        #expect(store.contains(uid: uid("retained"), descriptor: descriptorV1))
        #expect(!store.contains(uid: uid("removed"), descriptor: descriptorV1))
        #expect(store.contains(uid: uid("outside-baseline"), descriptor: descriptorV1))
        #expect(store.failureRecords(for: descriptorV1, from: [uid("failed-removed")]).isEmpty)
        #expect(store.generation(for: descriptorV1) == generation + 1)
    }

    @Test func failedAssetExcludedFromBatchUpsert() throws {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        store.recordFailures([
            MLIndexFailureRecord(uid: uid("a1"), descriptor: descriptorV1, kind: .permanent, attempts: 1)
        ])
        let plan = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        // Simulate embedding only the planned-to-index assets.
        let records = plan.toIndex.map { record($0.nodeID, descriptorV1, [1, 0, 0, 0]) }
        let report = store.upsert(records)
        #expect(report.indexed == 2)
        #expect(store.count(for: descriptorV1) == 2)
        // Re-plan: only the failed one stays excluded, the rest converge.
        let replan = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        #expect(replan.toIndex.isEmpty)
        #expect(replan.skippedAlreadyIndexed.count == 2)
        #expect(replan.skippedPermanentFailure.count == 1)
    }

    @Test func transientFailureIsRetriedOnNextPass() throws {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        // First pass: index a0, transient-fail a1 (not stored).
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let planAfter = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        // a1 wasn't stored, so it should re-enter toIndex on the next planning pass.
        #expect(planAfter.toIndex.map(\.nodeID) == ["a1"])
        // Second pass: now succeed with a1.
        store.upsert([record("a1", descriptorV1, [0, 1, 0, 0])])
        let planFinal = try MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        #expect(planFinal.toIndex.isEmpty)
        #expect(planFinal.isComplete)
    }

    @Test func progressStableAndUserReadable() {
        var progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 4)
        #expect(progress.fraction == 0)
        #expect(!progress.isComplete)

        progress.apply(MLIndexBatchReport(total: 2, indexed: 2))
        #expect(progress.indexed == 2)
        #expect(progress.settled == 2)
        #expect(progress.fraction == 0.5)

        progress.apply(MLIndexBatchReport(indexed: 1, permanentFailure: 1))
        #expect(progress.indexed == 3)
        #expect(progress.permanentFailure == 1)
        #expect(progress.fraction == 1.0)
        #expect(progress.isComplete)
        #expect(progress.phase == .completed)

        let summary = progress.summary
        #expect(summary.contains("complete"))
        #expect(summary.contains("fixture-model"))
    }

    @Test func progressHandlesZeroAssets() {
        let progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 0)
        #expect(progress.fraction == 0)
        #expect(!progress.summary.isEmpty)
    }

    @Test func progressTransientFailurePreventsCompletion() {
        var progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 3)
        progress.apply(MLIndexBatchReport(indexed: 2, transientFailure: 1))
        #expect(!progress.isComplete)
        #expect(progress.phase != .completed)
    }

    @Test func scoringReturnsDeterministicRankedResults() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),  // score 1.0
            record("a1", descriptorV1, [0.9, 0.1, 0, 0]),  // score 0.9
            record("a2", descriptorV1, [0, 0, 0, 1]),  // score 0.0
        ])
        let scorer = ReferenceDotProductScorer()
        let query: ContiguousArray<Float32> = [1, 0, 0, 0]
        let results = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: query, limit: 3)
        #expect(results.descriptor == descriptorV1)
        #expect(results.count == 3)
        #expect(results.results[0].uid == uid("a0"))
        #expect(results.results[0].score == 1.0)
        #expect(results.results[1].uid == uid("a1"))
        #expect(results.results[2].uid == uid("a2"))
        #expect(results.results[2].score == 0.0)
    }

    @Test func scoringIsDeterministicAcrossCalls() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [0.5, 0.5, 0, 0]),
            record("a1", descriptorV1, [0.4, 0.6, 0, 0]),
            record("a2", descriptorV1, [0.3, 0.7, 0, 0]),
        ])
        let scorer = ReferenceDotProductScorer()
        let query: ContiguousArray<Float32> = [1, 0, 0, 0]
        let r1 = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: query, limit: 10)
        let r2 = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: query, limit: 10)
        #expect(r1.results.map(\.uid.nodeID) == r2.results.map(\.uid.nodeID))
        #expect(r1.results.map(\.score) == r2.results.map(\.score))
    }

    @Test func scoringRespectsLimit() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0.5, 0, 0, 0]),
            record("a2", descriptorV1, [0.1, 0, 0, 0]),
        ])
        let scorer = ReferenceDotProductScorer()
        let results = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: [1, 0, 0, 0], limit: 2)
        #expect(results.count == 2)
        #expect(results.results[0].uid == uid("a0"))
    }

    @Test func scoringTieBreaksByRowOrder() {
        // Equal scores break by block row order (store key order) for deterministic results across
        // calls and store reopen, unlike wall-clock timestamps.
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("b-later", descriptorV1, [1, 0, 0, 0]),
            record("a-earlier", descriptorV1, [1, 0, 0, 0]),
        ])
        let scorer = ReferenceDotProductScorer()
        let results = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: [1, 0, 0, 0], limit: 2)
        #expect(results.results.map(\.uid.nodeID) == ["a-earlier", "b-later"])
    }

    @Test func scoringQueryDimensionMismatchReturnsEmpty() {
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let scorer = ReferenceDotProductScorer()
        let results = scorer.rank(block: store.vectorBlock(for: descriptorV1), query: [1, 0, 0, 0, 0], limit: 5)
        #expect(results.isEmpty)
    }

    @Test func topKSelectionMatchesFullSort() {
        // Structural check: bounded-heap top-k must equal a full sort's prefix, including the
        // (score desc, row asc) tie-break, for a mixed score buffer with duplicates.
        let scores: [Float32] = [0.3, 0.9, 0.9, 0.1, 0.5, 0.9, 0.5, 0.0, 1.0, 0.3]
        let fullOrder = scores.indices.sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }
        for limit in [1, 3, 5, scores.count, scores.count + 5] {
            let top = MLTopKSelector.select(scores: scores, limit: limit)
            #expect(top.map(\.row) == Array(fullOrder.prefix(limit)))
        }
    }

    @Test func noDuplicateRecordsForSameKey() {
        let store = InMemoryMLIndexStore()
        let r1 = record("a0", descriptorV1, [1, 0, 0, 0])
        let r2 = record("a0", descriptorV1, [0, 1, 0, 0])  // same key, different vector
        store.upsert([r1])
        let report = store.upsert([r2])
        #expect(report.skippedAlreadyIndexed == 1)
        #expect(store.count(for: descriptorV1) == 1)
        // The stored record is the first one (idempotent semantics: first write wins).
        let stored = store.vectorBlock(for: descriptorV1)
        #expect(stored.count == 1)
        // Guard the report/data agreement: the first-write-wins vector is retained, not r2's.
        #expect(stored.vectors.first == ContiguousArray([1, 0, 0, 0]))
    }

    @Test func containsReflectsCompositeKey() {
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        #expect(store.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV2))
        #expect(!store.contains(uid: uid("a1"), descriptor: descriptorV1))
    }

    @Test func storeReplaySimulatesRestart() {
        // Simulate a "restart" by creating a fresh store and re-loading the same records.
        let original = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        let savedRecords = assets.map { record($0.nodeID, descriptorV1, [1, 0, 0, 0]) }
        original.upsert(savedRecords)

        // "Persist" the records (in real life: serialize to disk). "Restart":
        let restarted = InMemoryMLIndexStore()
        restarted.upsert(savedRecords)
        // Idempotent re-load of the same records should not duplicate.
        let report = restarted.upsert(savedRecords)
        #expect(report.skippedAlreadyIndexed == 3)
        #expect(report.indexed == 0)
        #expect(restarted.count(for: descriptorV1) == 3)
    }

    @Test func storeRemoveOperations() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        store.remove(uids: [uid("a0")], descriptor: descriptorV1)
        #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(store.contains(uid: uid("a1"), descriptor: descriptorV1))
        #expect(store.count(for: descriptorV1) == 1)
        #expect(store.removeAll(for: descriptorV1))
        #expect(store.count(for: descriptorV1) == 0)
    }

    @Test func storeAllIndexedUIDsAndBulkMembership() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        let allUIDs = store.vectorBlock(for: descriptorV1).uids
        #expect(Set(allUIDs.map(\.nodeID)) == ["a0", "a1"])
        let membership = store.indexedUIDs(for: descriptorV1, from: [uid("a0"), uid("a2"), uid("a1")])
        #expect(membership == Set([uid("a0"), uid("a1")]))
    }

    @Test func batchReportMergeAccumulates() {
        let a = MLIndexBatchReport(total: 3, indexed: 2, skippedAlreadyIndexed: 1)
        let b = MLIndexBatchReport(
            total: 4, indexed: 1, skippedAlreadyIndexed: 1, permanentFailure: 1, transientFailure: 1)
        let merged = a.merge(b)
        #expect(merged.total == 7)
        #expect(merged.indexed == 3)
        #expect(merged.skippedAlreadyIndexed == 2)
        #expect(merged.permanentFailure == 1)
        #expect(merged.transientFailure == 1)
        #expect(!merged.settled)  // transient remains
    }

    @Test func dimensionMismatchRejected() {
        let store = InMemoryMLIndexStore()
        let valid = record("a0", descriptorV1, [1, 0, 0, 0])
        let tooShort = record("a1", descriptorV1, [1, 0])
        let report = store.upsert([valid, tooShort])
        // The mismatch is rejected and accounted: partitions always sum to total, so a bad
        // record can never silently vanish from progress reporting.
        #expect(report.indexed == 1)
        #expect(report.permanentFailure == 1)
        #expect(
            report.total == report.indexed + report.skippedAlreadyIndexed + report.permanentFailure
                + report.transientFailure)
        #expect(store.count(for: descriptorV1) == 1)
        #expect(!store.contains(uid: uid("a1"), descriptor: descriptorV1))
    }

    @Test func descriptorDisplayName() {
        #expect(descriptorV1.displayName == "fixture-model v1 (4d)")
        #expect(descriptorV2.displayName == "fixture-model v2 (4d)")
    }
}
