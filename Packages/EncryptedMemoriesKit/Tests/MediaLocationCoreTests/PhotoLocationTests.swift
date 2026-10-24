import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaLocationCore

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: n) }
private func coord(_ n: String, _ lat: Double, _ lon: Double) -> PhotoCoordinate {
    PhotoCoordinate(uid: uid(n), latitude: lat, longitude: lon, date: Date(timeIntervalSince1970: 0))
}
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("loctest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class LocationWriteBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var entryCount = 0

    func block() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func blockFirst() {
        condition.lock()
        entryCount += 1
        entered = true
        condition.broadcast()
        guard entryCount == 1 else {
            condition.unlock()
            return
        }
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() {
        condition.lock()
        while !entered { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite struct PhotoLocationStoreTests {
    @Test func roundTripsEncryptedCoordinates() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        let coords = [coord("a", 47.8, 13.0), coord("b", 47.4, 12.5)]
        store.save(coords)

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load() == coords)
    }

    @Test func onDiskBlobIsNeverPlaintext() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("secret", 47.812345, 13.044444)])

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.isEmpty)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("47.812345"))  // coordinate not in cleartext
    }

    @Test func wrongKeyOrAccountReadsEmpty() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("a", 47.8, 13.0)])

        let wrongKey = PhotoLocationStore(directory: dir)
        wrongKey.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        #expect(wrongKey.load().isEmpty)

        let wrongAccount = PhotoLocationStore(directory: dir)
        wrongAccount.configure(accountUID: "other", key: SymmetricKey(size: .bits256))
        #expect(wrongAccount.load().isEmpty)
    }

    @Test func discardsLegacyDerivedStoreWithoutMigratingIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let coordinates = [coord("legacy", 47.8, 13.0)]
        let plain = try JSONEncoder().encode(coordinates)
        let aad = Data("encryptedmemories.locations.v1|acct=acct".utf8)
        let sealed = try #require(try AES.GCM.seal(plain, using: key, authenticating: aad).combined)
        try sealed.write(to: dir.appendingPathComponent("locations.v1.enc"))

        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("locations.v1.enc").path))
    }

    @Test func clearErasesTheBlob() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        store.save([coord("a", 47.8, 13.0)])
        store.clear()

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load().isEmpty)
    }

    @Test func staleSessionLeaseCannotWriteAfterAccountReplacement() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        let oldLease = store.configure(accountUID: "old", key: SymmetricKey(size: .bits256))
        store.configure(accountUID: "new", key: SymmetricKey(size: .bits256))

        store.save([coord("old", 47.8, 13.0)], ifCurrent: oldLease)

        #expect(store.load().isEmpty)
    }
}

@Suite @MainActor struct PhotoLocationIndexTests {
    @Test func mergeDedupsByUIDAndBumpsRevisionOnlyWhenChanged() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 1, 1), coord("b", 2, 2)])
        #expect(index.coordinates.count == 2)

        let r = index.revision
        index.merge([coord("a", 1, 1)])  // pure duplicate
        #expect(index.coordinates.count == 2)
        #expect(index.revision == r)  // no change, so no view churn

        index.merge([coord("c", 3, 3)])
        #expect(index.coordinates.count == 3)
        #expect(index.revision == r + 1)
    }

    @Test func coordinateSupersedesNegativeCacheEntry() {
        let index = PhotoLocationIndex()
        let missing = uid("missing")
        #expect(!index.hasKnownLocation(missing))
        #expect(index.markNoLocation([missing]) == [missing])
        #expect(!index.hasKnownLocation(missing))

        #expect(index.merge([coord("missing", 47.8, 13.0)]).map(\.uid) == [missing])
        #expect(index.coordinates.map(\.uid) == [missing])
        #expect(index.snapshot().noLocationUIDs.isEmpty)
        #expect(index.hasKnownLocation(missing))
    }

    @Test func failedJournalAppendRecoversWithACompleteSnapshot() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir, journalCompactionThresholdBytes: Int.max)
        store.configure(accountUID: "acct", key: key)
        let index = PhotoLocationIndex()
        let first = index.merge([coord("first", 47.8, 13.0)])
        #expect(await index.persistDelta(coordinates: first, noLocationUIDs: [], to: store))

        let journal = try #require(
            try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasSuffix(".journal.log") }))
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)

        let second = index.merge([coord("second", 48.0, 14.0)])
        #expect(await index.persistDelta(coordinates: second, noLocationUIDs: [], to: store))

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(Set(reopened.load().map(\.uid)) == Set([uid("first"), uid("second")]))
    }

    @Test func libraryReconcileRemovesAndPersistsDeletedPinsWithoutLateResurrection() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        let index = PhotoLocationIndex()
        index.merge([coord("keep", 1, 1), coord("delete", 2, 2)])

        await index.retainOnly([uid("keep")], persistTo: store)
        index.merge([coord("delete", 2, 2)])

        #expect(index.coordinates.map(\.uid) == [uid("keep")])
        #expect(store.load().map(\.uid) == [uid("keep")])

        await index.retainOnly([uid("keep"), uid("delete")])
        index.merge([coord("delete", 2, 2)])
        #expect(Set(index.coordinates.map(\.uid)) == [uid("keep"), uid("delete")])
    }

    @Test func theScannedLibraryIsAcceptedOnTopOfTheCleanUpLibraryAndReplacedByTheNextScan() async {
        func inventory(_ names: [String]) -> LocationCrawlInventory {
            LocationCrawlInventory(
                uids: names.map(uid), captureDates: Dictionary(uniqueKeysWithValues: names.map { (uid($0), Date()) }))
        }
        let index = PhotoLocationIndex()
        // Before a clean-up the index accepts every photo, and accepting a library changes nothing.
        index.accept(inventory(["early"]), revision: 1)
        #expect(index.merge([coord("anything", 1, 1)]).map(\.uid) == [uid("anything")])

        await index.retainOnly([uid("kept")], afterInventoryRevision: 1)
        index.accept(inventory(["added", "restored", "later", "pending"]), revision: 2)
        #expect(
            index.merge([coord("added", 1, 1), coord("restored", 2, 2), coord("unknown", 3, 3)]).map(\.uid)
                == [uid("added"), uid("restored")],
            "The scan stores results for its library, not for a photo that no library has")
        #expect(
            index.markNoLocation([uid("later"), uid("unknown")]) == [uid("later")],
            "A result without a location is admitted exactly like a coordinate")

        // A newer scan replaces the library of the older one. The clean-up library stays accepted.
        index.accept(inventory(["added"]), revision: 3)
        #expect(index.merge([coord("pending", 4, 4)]).isEmpty, "A photo that the newer library lacks is not accepted")
        #expect(index.markNoLocation([uid("pending")]).isEmpty)
        #expect(index.merge([coord("kept", 5, 5)]).map(\.uid) == [uid("kept")])

        // A list that was read before the accepted one is ignored.
        index.accept(inventory(["pending"]), revision: 2)
        #expect(index.merge([coord("pending", 4, 4)]).isEmpty, "A late older list must not replace a newer one")

        // A list that is not newer than the last clean-up never undoes it; a newer list does.
        await index.retainOnly([uid("kept")], afterInventoryRevision: 3)
        index.accept(inventory(["stale"]), revision: 3)
        #expect(index.merge([coord("stale", 6, 6)]).isEmpty, "A list read before the clean-up must not undo it")
        index.accept(inventory(["fresh"]), revision: 4)
        #expect(index.merge([coord("fresh", 7, 7)]).map(\.uid) == [uid("fresh")])

        // A later clean-up starts from its own library: the library of the earlier scan does not survive it.
        await index.retainOnly([uid("kept")], afterInventoryRevision: 4)
        #expect(index.markNoLocation([uid("fresh")]).isEmpty)
        #expect(index.merge([coord("added", 1, 1)]).isEmpty)
    }

    @Test func staleReconcileCannotPersistIntoReplacementAccount() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        let staleLease = store.configure(accountUID: "old", key: SymmetricKey(size: .bits256))
        let index = PhotoLocationIndex()
        index.merge([coord("new", 2, 2)])
        store.configure(accountUID: "new", key: SymmetricKey(size: .bits256))

        await index.retainOnly([uid("old")], persistTo: store, sessionLease: staleLease)

        #expect(index.coordinates.map(\.uid) == [uid("new")])
        #expect(store.load().isEmpty)
    }

    #if DEBUG
        @Test func accountReplacementDuringBlockedReconcileRejectsLateWrite() async {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = PhotoLocationStore(directory: dir)
            let staleLease = store.configure(accountUID: "old", key: SymmetricKey(size: .bits256))
            let index = PhotoLocationIndex()
            index.merge([coord("old", 1, 1)])
            let barrier = LocationWriteBarrier()
            store.setBeforeWriteHook { barrier.block() }

            let reconcile = Task {
                await index.retainOnly([uid("old")], persistTo: store, sessionLease: staleLease)
            }
            await Task.detached { barrier.waitUntilEntered() }.value
            store.configure(accountUID: "new", key: SymmetricKey(size: .bits256))
            barrier.release()
            await reconcile.value
            store.setBeforeWriteHook(nil)

            #expect(store.load().isEmpty)
        }

        @Test func olderSameAccountSnapshotCannotOverwriteNewerReconcile() async {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = PhotoLocationStore(directory: dir)
            let lease = store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
            let index = PhotoLocationIndex()
            index.merge([coord("keep", 1, 1), coord("delete", 2, 2)])
            let barrier = LocationWriteBarrier()
            store.setBeforeWriteHook { barrier.blockFirst() }

            let older = Task {
                await index.retainOnly(
                    [uid("keep"), uid("delete")],
                    persistTo: store,
                    sessionLease: lease
                )
            }
            await Task.detached { barrier.waitUntilEntered() }.value
            await index.retainOnly([uid("keep")], persistTo: store, sessionLease: lease)
            barrier.release()
            await older.value
            store.setBeforeWriteHook(nil)

            #expect(store.load().map(\.uid) == [uid("keep")])
        }
    #endif

    @Test func boundingBoxFiltersToVisibleRegion() {
        let index = PhotoLocationIndex()
        index.merge([coord("inside", 47.8, 13.0), coord("outside", 10.0, 10.0)])
        let box = GeoBoundingBox(minLatitude: 47, maxLatitude: 48, minLongitude: 12, maxLongitude: 14)
        let hits = index.coordinates(in: box)
        #expect(hits.map(\.uid) == [uid("inside")])
    }

    @Test func bucketedQueryHandlesWrappedLongitudeWithoutWholeIndexScan() {
        let index = PhotoLocationIndex()
        index.merge([
            coord("west", 0, -179.5),
            coord("east", 0, 179.5),
            coord("middle", 0, 0),
        ])
        let box = GeoBoundingBox(minLatitude: -1, maxLatitude: 1, minLongitude: 179, maxLongitude: -179)
        let hits = index.querySnapshot().coordinates(in: box)

        #expect(Set(hits.map(\.uid)) == Set([uid("west"), uid("east")]))
    }

    @Test func viewportPolicyMatchesVisibleMapRectMarginFormula() {
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1.6, maxCells: 400, cellDivisor: 12)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.5,
            centerLongitude: 13.0,
            latitudeDelta: 0.5,
            longitudeDelta: 1.25
        )

        let box = policy.boundingBox(for: viewport)
        #expect(
            box
                == GeoBoundingBox(
                    minLatitude: 47.1,
                    maxLatitude: 47.9,
                    minLongitude: 12.0,
                    maxLongitude: 14.0
                ))
    }

    @Test func viewportPolicyBinsNearbyCoordinatesIntoOneCell() {
        let index = PhotoLocationIndex()
        // Three photos close enough to fall into the same grid cell, plus one far away.
        index.merge([
            coord("a", 47.6994, 13.0002),
            coord("b", 47.6998, 13.0004),
            coord("c", 47.7001, 13.0006),
            coord("far", 48.000, 14.000),
        ])
        // Large cellDivisor with a tight viewport ensures the three near photos share a cell, while
        // the far one lands in its own. Margin 1 keeps the box tight so `far` is excluded entirely.
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1, maxCells: 100, cellDivisor: 6)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.701,
            centerLongitude: 13.001,
            latitudeDelta: 0.01,
            longitudeDelta: 0.01
        )

        let cells = index.coordinates(in: viewport, policy: policy)
        // One cell aggregates the three near photos; `far` is outside the box.
        #expect(cells.count == 1, "expected one cell; got \(cells.count)")
        #expect(cells[0].count == 3, "expected 3 members in the cell; got \(cells[0].count)")
    }

    @Test func minCellMetersFloorCollapsesSamePlaceBurstEvenWhenZoomedIn() {
        let index = PhotoLocationIndex()
        // A burst at essentially one spot, spread by ~30 m of GPS noise (0.0003° lat ≈ 33 m).
        index.merge([
            coord("a", 47.69960, 13.00020),
            coord("b", 47.70010, 13.00060),
            coord("c", 47.69985, 13.00040),
        ])
        // A tightly zoomed-in viewport (~110 m tall): with cellDivisor 12 the raw cell is ~9 m, so
        // Without a floor these three points scatter into separate cells. An 80 m floor
        // forces them into one.
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.70000,
            centerLongitude: 13.00000,
            latitudeDelta: 0.001,
            longitudeDelta: 0.001
        )

        let noFloor = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2, maxCells: 400, cellDivisor: 12)
        #expect(
            index.coordinates(in: viewport, policy: noFloor).count > 1,
            "control: without a floor the burst should scatter into multiple cells")

        let floored = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 2, maxCells: 400, cellDivisor: 12, minCellMeters: 80)
        let cells = index.coordinates(in: viewport, policy: floored)
        #expect(cells.count == 1, "expected one cell with the 80 m floor; got \(cells.count)")
        #expect(cells.first?.count == 3, "the single cell must carry all 3 photos; got \(cells.first?.count ?? -1)")
    }

    @Test func viewportPolicyRejectsInvalidInputsWithoutLeakingAllCoordinates() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 47.8, 13.0)])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: .infinity, maxCells: 400, cellDivisor: 12)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.7,
            centerLongitude: 13.1,
            latitudeDelta: 0.5,
            longitudeDelta: 0.5
        )

        #expect(index.coordinates(in: viewport, policy: policy).isEmpty)
    }

    /// Sub-pixel viewport jitter must not change which cells exist
    /// or which photos each cell holds. The aggregation bins by integer cell indices, so a fractional
    /// shift of the center keeps the same cells (just possibly re-keyed, but still bounded) - the
    /// member sets per cell must stay identical.
    @Test func viewportPolicyCellsAreStableAcrossSmallViewportJitter() {
        let index = PhotoLocationIndex()
        let center = (lat: 47.7045, lon: 13.1045)
        // Spread photos across a few distinct cells so aggregation is meaningful.
        index.merge([
            coord("a", center.lat, center.lon),
            coord("b", center.lat + 0.01, center.lon),
            coord("c", center.lat + 0.02, center.lon),
            coord("d", center.lat, center.lon + 0.01),
            coord("e", center.lat, center.lon + 0.02),
        ])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2.0, maxCells: 10, cellDivisor: 10)

        let viewportA = PhotoLocationViewport(
            centerLatitude: center.lat, centerLongitude: center.lon,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )
        let viewportB = PhotoLocationViewport(
            centerLatitude: center.lat + 0.0000001, centerLongitude: center.lon + 0.0000001,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )

        let cellsA = index.coordinates(in: viewportA, policy: policy)
        let cellsB = index.coordinates(in: viewportB, policy: policy)
        // Same set of heroes (cell identities are stable) and same total photo count.
        #expect(
            Set(cellsA.map(\.uid)) == Set(cellsB.map(\.uid)),
            "cell heroes must be stable across sub-pixel jitter")
        let totalA = cellsA.reduce(0) { $0 + $1.count }
        let totalB = cellsB.reduce(0) { $0 + $1.count }
        #expect(totalA == totalB, "total photo coverage must be stable")
        #expect(totalA == 5, "all five photos must be represented")
    }

    @Test func aggregationPreservesEveryPhotoAcrossCells() {
        let index = PhotoLocationIndex()
        // 20 photos spread so each cell gets ~2 members - none should be dropped.
        var coords: [PhotoCoordinate] = []
        for i in 0..<20 {
            coords.append(coord("p\(i)", 47.0 + Double(i % 4) * 0.01, 13.0 + Double(i / 4) * 0.01))
        }
        index.merge(coords)
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2.0, maxCells: 50, cellDivisor: 10)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.015, centerLongitude: 13.015,
            latitudeDelta: 0.05, longitudeDelta: 0.05
        )
        let cells = index.coordinates(in: viewport, policy: policy)
        let totalMembers = cells.reduce(0) { $0 + $1.count }
        #expect(totalMembers == 20, "every photo must be accounted for; got \(totalMembers)")
    }

    @Test func capKeepsTheDensestCellEvenWhenItIsFarFromCenter() {
        let index = PhotoLocationIndex()
        var coords: [PhotoCoordinate] = []
        // Many sparse single-photo cells clustered near the viewport center.
        for i in 0..<40 {
            coords.append(coord("near\(i)", 47.500 + Double(i) * 0.001, 13.500))
        }
        // One very dense place far from center (the "home with 2000 photos" case, scaled down): 50
        // photos within one cell, off to the side.
        for i in 0..<50 {
            coords.append(coord("home\(i)", 47.600 + Double(i) * 0.00001, 13.700))
        }
        index.merge(coords)
        // A tight cap forces adaptive coarsening. It must merge cells rather than discard any photo.
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 10, maxCells: 10, cellDivisor: 50)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.500, centerLongitude: 13.500,
            latitudeDelta: 0.05, longitudeDelta: 0.05
        )
        let cells = index.coordinates(in: viewport, policy: policy)
        #expect(cells.count <= 10, "cap must be applied; got \(cells.count)")
        #expect(cells.reduce(0) { $0 + $1.count } == 90, "the cap must not discard members")
        let densest = cells.map(\.count).max() ?? 0
        #expect(densest >= 50, "the dense place must remain represented; got \(densest)")
    }

    @Test func adaptiveCellBudgetConservesEveryUID() {
        let coordinates = (0..<5_000).map { index in
            coord(
                "p\(index)",
                -70 + Double(index % 100) * 1.4,
                -170 + Double(index / 100) * 6.8
            )
        }
        let viewport = PhotoLocationViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 180,
            longitudeDelta: 360
        )
        let cells = PhotoLocationAggregation.aggregate(
            coordinates,
            in: viewport,
            cellDivisor: 100,
            maxCells: 40
        )

        let members = cells.flatMap(\.memberUIDs)
        #expect(cells.count <= 40)
        #expect(members.count == coordinates.count)
        #expect(Set(members).count == coordinates.count)
    }

    @Test func aggregationDisplaysAtTheMemberCentroidInsteadOfAnUnrelatedCellCenter() throws {
        let viewport = PhotoLocationViewport(
            centerLatitude: 10,
            centerLongitude: 20,
            latitudeDelta: 10,
            longitudeDelta: 10
        )
        let cells = PhotoLocationAggregation.aggregate(
            [coord("a", 10, 20), coord("b", 12, 22)],
            in: viewport,
            cellDivisor: 1,
            maxCells: 10
        )

        #expect(cells.count == 1)
        let cell = try #require(cells.first)
        #expect(abs(cell.latitude - 11) < 0.000_001)
        #expect(abs(cell.longitude - 21) < 0.000_001)
    }

    @Test func coarseWorldClusterOfAustrianPhotosStaysInAustria() throws {
        let cells = PhotoLocationAggregation.aggregate(
            [coord("home-a", 48.20, 16.30), coord("home-b", 48.22, 16.34)],
            in: PhotoLocationViewport(
                centerLatitude: 0, centerLongitude: 0,
                latitudeDelta: 180, longitudeDelta: 360
            ),
            cellDivisor: 1,
            maxCells: 1
        )

        let cell = try #require(cells.first)
        #expect(cells.count == 1)
        #expect((47.0...49.0).contains(cell.latitude))
        #expect(
            (15.0...17.0).contains(cell.longitude),
            "a coarse grid cell must not move Lower Austria to the cell center in western Kazakhstan")
    }

    @Test func pointBudgetPreservesUIDPartitionAcrossZoomLevels() {
        let coordinates = (0..<400).map { index in
            coord(
                "p\(index)",
                47.42 + Double(index % 20) * 0.008,
                12.92 + Double(index / 20) * 0.008
            )
        }
        let policy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1,
            maxCells: 400,
            cellDivisor: 40,
            minimumPinSpacingPoints: 64
        )
        let size = PhotoLocationViewportSize(widthPoints: 390, heightPoints: 844)
        let fine = policy.aggregatedCoordinates(
            from: coordinates,
            in: PhotoLocationViewport(
                centerLatitude: 47.5, centerLongitude: 13,
                latitudeDelta: 0.2, longitudeDelta: 0.2
            ),
            viewportSize: size
        )
        let coarse = policy.aggregatedCoordinates(
            from: coordinates,
            in: PhotoLocationViewport(
                centerLatitude: 47.5, centerLongitude: 13,
                latitudeDelta: 0.4, longitudeDelta: 0.4
            ),
            viewportSize: size
        )

        for cells in [fine, coarse] {
            let members = cells.flatMap(\.memberUIDs)
            #expect(cells.count <= policy.maxCells)
            #expect(members.count == coordinates.count)
            #expect(
                Set(members).count == coordinates.count,
                "every zoom level must remain a disjoint, complete UID partition")
        }
        #expect(fine.count >= coarse.count)

        let coarseCellByUID = Dictionary(
            uniqueKeysWithValues: coarse.flatMap { cell in
                cell.memberUIDs.map { ($0, cell.cellID) }
            })
        for fineCell in fine {
            let parents = Set(fineCell.memberUIDs.compactMap { coarseCellByUID[$0] })
            #expect(
                parents.count == 1,
                "a fine display cell must map wholly into one coarser parent, never disappear between zooms")
        }
    }

    @Test func pointBudgetAdaptsToPortraitAndLandscapeWithoutLosingMembers() throws {
        let coordinates = (0..<400).map { index in
            coord(
                "orientation-\(index)",
                47.42 + Double(index % 20) * 0.008,
                12.92 + Double(index / 20) * 0.008
            )
        }
        let policy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1,
            maxCells: 400,
            cellDivisor: 40,
            minimumPinSpacingPoints: 64
        )
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.5, centerLongitude: 13,
            latitudeDelta: 0.2, longitudeDelta: 0.2
        )
        let portrait = policy.aggregatedCoordinates(
            from: coordinates,
            in: viewport,
            viewportSize: PhotoLocationViewportSize(widthPoints: 390, heightPoints: 844)
        )
        let landscape = policy.aggregatedCoordinates(
            from: coordinates,
            in: viewport,
            viewportSize: PhotoLocationViewportSize(widthPoints: 844, heightPoints: 390)
        )

        let portraitPlan = try #require(
            policy.aggregationPlan(
                for: viewport,
                viewportSize: PhotoLocationViewportSize(widthPoints: 390, heightPoints: 844)
            ))
        let landscapePlan = try #require(
            policy.aggregationPlan(
                for: viewport,
                viewportSize: PhotoLocationViewportSize(widthPoints: 844, heightPoints: 390)
            ))
        #expect(
            portraitPlan.resolution.latitudeStepExponent
                < landscapePlan.resolution.latitudeStepExponent)
        #expect(
            portraitPlan.resolution.longitudeCellCountExponent
                < landscapePlan.resolution.longitudeCellCountExponent)

        let expectedUIDs = Set(coordinates.map(\.uid))
        for cells in [portrait, landscape] {
            let members = cells.flatMap(\.memberUIDs)
            #expect(members.count == coordinates.count)
            #expect(Set(members) == expectedUIDs)
        }
    }

    @Test func aggregationResolutionDoesNotCollapseAtOccupiedCellThreshold() throws {
        let policy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1.6,
            maxCells: 400,
            cellDivisor: 12,
            minimumPinSpacingPoints: 64
        )
        let size = PhotoLocationViewportSize(widthPoints: 800, heightPoints: 800)
        let viewportA = PhotoLocationViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 0.75,
            longitudeDelta: 1.054_687_5
        )
        let viewportB = PhotoLocationViewport(
            centerLatitude: 0.000_001,
            centerLongitude: 0.000_001,
            latitudeDelta: viewportA.latitudeDelta,
            longitudeDelta: viewportA.longitudeDelta
        )
        let planA = try #require(policy.aggregationPlan(for: viewportA, viewportSize: size))
        let planB = try #require(policy.aggregationPlan(for: viewportB, viewportSize: size))
        #expect(
            planA.resolution == planB.resolution,
            "sub-cell pans must not choose resolution from the occupied-bin count")

        let coordinates = (0..<441).map { index in
            coord(
                "threshold-\(index)",
                -0.55 + Double(index % 21) * 0.055,
                -0.78 + Double(index / 21) * 0.078
            )
        }
        let cellsA = policy.aggregatedCoordinates(from: coordinates, using: planA)
        let cellsB = policy.aggregatedCoordinates(from: coordinates, using: planB)
        #expect(cellsA == cellsB)
        #expect(cellsA.count <= policy.maxCells)
        #expect(Set(cellsA.flatMap(\.memberUIDs)) == Set(coordinates.map(\.uid)))
    }

    @Test func oneCellBudgetTerminatesAndConservesTheFullWorld() {
        let coordinates = (0..<500).map { index in
            coord(
                "world-\(index)",
                -89 + Double(index % 100) * 1.78,
                -179 + Double(index / 100) * 71.6
            )
        }
        let cells = PhotoLocationAggregation.aggregate(
            coordinates,
            in: PhotoLocationViewport(
                centerLatitude: 0, centerLongitude: 0,
                latitudeDelta: 180, longitudeDelta: 360
            ),
            cellDivisor: 100,
            maxCells: 1
        )

        #expect(cells.count == 1)
        #expect(cells.first?.memberUIDs.count == coordinates.count)
        #expect(Set(cells.flatMap(\.memberUIDs)) == Set(coordinates.map(\.uid)))
    }

    @Test func circularLongitudeGridClosesTheAntimeridianSeam() throws {
        let policy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1,
            maxCells: 400,
            cellDivisor: 12
        )
        let viewport = PhotoLocationViewport(
            centerLatitude: 0, centerLongitude: 180,
            latitudeDelta: 10, longitudeDelta: 360
        )
        let cells = policy.aggregatedCoordinates(
            from: [coord("west", 0, -179), coord("east", 0, 179)],
            in: viewport,
            viewportSize: PhotoLocationViewportSize(widthPoints: 800, heightPoints: 800)
        )

        #expect(cells.count == 2)
        #expect(Set(cells.flatMap(\.memberUIDs)).count == 2)
        let first = try #require(cells.first)
        let last = try #require(cells.last)
        let rawDistance = abs(first.longitude - last.longitude)
        let circularDistance = min(rawDistance, 360 - rawDistance)
        #expect(abs(circularDistance - 2) < 0.000_001)
        #expect(first.cellID.longitudeCellCountExponent == last.cellID.longitudeCellCountExponent)
    }

    @Test func circularLongitudeGridHasStableParentsAcrossCoarseLevels() {
        let coordinates = stride(from: -179.0, through: 179.0, by: 2.0).enumerated().map {
            coord("seam-parent-\($0.offset)", 0, $0.element)
        }
        let viewport = PhotoLocationViewport(
            centerLatitude: 0, centerLongitude: 0,
            latitudeDelta: 10, longitudeDelta: 360
        )
        let finePolicy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1, maxCells: 400, cellDivisor: 22.5
        )
        let coarsePolicy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1, maxCells: 400, cellDivisor: 11.25
        )
        let fine = finePolicy.aggregatedCoordinates(from: coordinates, in: viewport)
        let coarse = coarsePolicy.aggregatedCoordinates(from: coordinates, in: viewport)
        let coarseCellByUID = Dictionary(
            uniqueKeysWithValues: coarse.flatMap { cell in
                cell.memberUIDs.map { ($0, cell.cellID) }
            })

        for fineCell in fine {
            let parents = Set(fineCell.memberUIDs.compactMap { coarseCellByUID[$0] })
            #expect(parents.count == 1)
            if let parent = parents.first {
                #expect(
                    parent.longitudeCellCountExponent
                        == fineCell.cellID.longitudeCellCountExponent - 1)
                #expect(parent.longitudeIndex == fineCell.cellID.longitudeIndex / 2)
            }
        }
    }

    @Test func aggregationPlanIgnoresResizeNoiseUntilTheGridChanges() throws {
        let policy = PhotoLocationVisibleCoordinatePolicy.standard
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.5, centerLongitude: 13,
            latitudeDelta: 1, longitudeDelta: 1
        )
        let size800 = try #require(
            policy.aggregationPlan(
                for: viewport,
                viewportSize: PhotoLocationViewportSize(widthPoints: 800, heightPoints: 800)
            ))
        let size801 = try #require(
            policy.aggregationPlan(
                for: viewport,
                viewportSize: PhotoLocationViewportSize(widthPoints: 801, heightPoints: 801)
            ))
        let size512 = try #require(
            policy.aggregationPlan(
                for: viewport,
                viewportSize: PhotoLocationViewportSize(widthPoints: 512, heightPoints: 512)
            ))

        #expect(size800 == size801)
        #expect(size800.resolution != size512.resolution)
    }

    @Test func wrappedBoundingBoxIncludesBothSidesOfAntimeridian() {
        let policy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1,
            maxCells: 20,
            cellDivisor: 4
        )
        let viewport = PhotoLocationViewport(
            centerLatitude: 0,
            centerLongitude: 179,
            latitudeDelta: 10,
            longitudeDelta: 8
        )
        let box = policy.boundingBox(for: viewport)
        #expect(box?.minLongitude == 175)
        #expect(box?.maxLongitude == -177)
        #expect(box?.contains(latitude: 0, longitude: 178) == true)
        #expect(box?.contains(latitude: 0, longitude: -179) == true)
        #expect(box?.contains(latitude: 0, longitude: 0) == false)
    }
}

@Suite("MediaLocationCore platform purity")
struct MediaLocationCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaLocationCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CryptoKit",
        "Foundation",
        "Observation",
        "PhotosCore",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "MediaLocationCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(
            seen.subtracting(Self.allowedFrameworkImports).isEmpty,
            "Unexpected MediaLocationCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageOrHardwarePolicyTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            violations.isEmpty,
            "MediaLocationCore must not reference platform UI types or hardware policy:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}
