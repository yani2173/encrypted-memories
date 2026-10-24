import CryptoKit
import Foundation
import MediaByteCache
import MediaFeedCore
import Observation
import PhotosCore
import Testing

@testable import MediaLocationCore
@testable import TimelineCore

@Suite @MainActor struct WholeLibraryLocationSeamBaselineTests {
    @Test(.timeLimit(.minutes(1)))
    func knownCompleteInventoryUsesTheProductionStartEntry() async throws {
        let fixture = try await LocationInventoryFixture.make()
        await fixture.publish(fixture.items)
        await fixture.finishAdmittedCrawl()
        #expect(Set(fixture.probes.values) == Set(fixture.items.map(\.uid)))
        #expect(fixture.session.isStarted)
        #expect(fixture.persistedUIDs() == Set(fixture.items.map(\.uid)))
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRepeatedCompleteStartKeepsTheActiveStarter() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let release = InventoryGate()
        defer { release.open() }
        let prerequisite = Task { await release.wait() }
        await fixture.publish(fixture.items, awaiting: prerequisite)
        let first = fixture.session.startingTask
        await fixture.publish(fixture.items, awaiting: prerequisite)
        #expect(first != nil)
        #expect(fixture.session.startingTask == first)
        release.open()
        await prerequisite.value
        await fixture.finishAdmittedCrawl()
        #expect(fixture.probes.values.count == fixture.items.count)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitEmptyReconciliationClearsAndPersists() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.seed(["b", "d"])
        await fixture.reconcile([])
        #expect(fixture.index.coordinates.isEmpty)
        #expect(fixture.persistedUIDs().isEmpty)
        #expect(fixture.probes.values.isEmpty)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRestoreDoesNotActivateAnUnusedCrawl() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.seed(["b", "d"])
        await fixture.reconcile(fixture.items, restoring: true)
        #expect(!fixture.session.isStarted)
        #expect(fixture.session.startingTask == nil)
        #expect(fixture.probes.values.isEmpty)
        #expect(fixture.persistedUIDs() == [inventoryUID("b")])
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anActiveRestoreToEmptyKeepsThePriorRestartSemantics() async throws {
        let fixture = try await LocationInventoryFixture.make()
        await fixture.publish(fixture.items)
        await fixture.finishAdmittedCrawl()
        let probesBefore = fixture.probes.values
        #expect(fixture.session.isStarted)
        await fixture.reconcile([], restoring: true)
        #expect(!fixture.session.isStarted)
        #expect(fixture.probes.values == probesBefore)
        #expect(fixture.persistedUIDs().isEmpty)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aKnownWholeSnapshotStaysCompleteUnderAnAlbum() async throws {
        let fixture = try await LocationInventoryFixture.make(online: true)
        await fixture.timeline.load()
        await fixture.timeline.select(LocationInventoryRepository.album)
        #expect(fixture.timeline.allItems.map(\.uid) == [inventoryUID("a")])
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        await fixture.publish(fixture.timeline.wholeLibraryItemsForLocations)
        await fixture.finishAdmittedCrawl()
        #expect(Set(fixture.probes.values) == Set(fixture.items.map(\.uid)))
        await fixture.close()
    }

    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func aRetiredCallbackCannotReconcileTheReplacementAccount() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            let owner = Task { await fixture.reconcile([inventoryItem("a")]) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            fixture.currentAccount = false
            let retired = fixture.session.retire()
            let replacementKey = SymmetricKey(size: .bits256)
            fixture.store.configure(accountUID: "replacement", key: replacementKey)
            fixture.index.replaceAll([inventoryCoordinate("c")])
            fixture.store.save([inventoryCoordinate("c")])
            release.open()
            await owner.value
            await retired?.value
            #expect(fixture.index.coordinates.map(\.uid) == [inventoryUID("c")])
            #expect(fixture.persistedUIDs(account: "replacement", key: replacementKey) == [inventoryUID("c")])
            #expect(!fixture.session.isStarted)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func projectionHookHoldsTheActualWorkerAndJoinsCleanup() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            let owner = Task {
                await fixture.reconcile([inventoryItem("b")])
                fixture.events.send(.ownerFinished)
            }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            #expect(Set(fixture.index.coordinates.map(\.uid)) == [inventoryUID("b"), inventoryUID("d")])
            #expect(fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")])
            release.open()
            #expect(await events.next() == .ownerFinished)
            await owner.value
            #expect(fixture.persistedUIDs() == [inventoryUID("b")])
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func nilProjectionHookKeepsKnownFullReconciliation() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            #expect(fixture.session.beforeWholeLibraryUIDProjectionForTesting == nil)
            await fixture.reconcile(fixture.items)
            #expect(fixture.persistedUIDs() == [inventoryUID("b")])
            #expect(fixture.index.coordinates.map(\.uid) == [inventoryUID("b")])
            await fixture.close()
        }
    #endif
}

@Suite @MainActor struct WholeLibraryLocationInventoryTests {
    @Test(.timeLimit(.minutes(1)))
    func offlineAlbumAndTwoReconnectsWaitForWholeLibrary() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.seed(["b", "d"])
        await fixture.timeline.load()
        await fixture.timeline.select(LocationInventoryRepository.album)
        #expect(await fixture.repository.fullReads == 1)
        #expect(await fixture.repository.filteredReads == 1)

        await fixture.repository.setOnline()
        for reconnect in 1...2 {
            await fixture.timeline.retry()
            #expect(fixture.timeline.allItems.map(\.uid) == [inventoryUID("a")])
            #expect(
                fixture.timeline.wholeLibraryItemsForLocations == nil,
                "M684_UNKNOWN_ALBUM: reconnect must not manufacture a whole-library snapshot")
            let completedBefore = fixture.events.completedCrawls
            fixture.session.startWholeLibrary(
                items: fixture.timeline.wholeLibraryItemsForLocations, restarting: true
            ) { fixture.makeStart() }
            #expect(
                fixture.session.startingTask == nil && !fixture.session.isStarted,
                "M684_NO_SUBSET_START: an unknown library must not admit a starter or restart")
            // Join any incorrectly admitted work before observing its effects. A nil starter admits no worker.
            await fixture.finishAdmittedCrawl(after: completedBefore)
            #expect(fixture.probes.values.isEmpty, "M684_NO_SUBSET_PROBE: an album must not become crawl inventory")
            #expect(await fixture.repository.fullReads == 1, "M684_NO_BACKGROUND_ALL: reconnect reloads its route")
            #expect(await fixture.repository.filteredReads == reconnect + 1)
        }

        await fixture.timeline.commitTrash([inventoryItem("d")])
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
            "M684_UNKNOWN_PRESERVES_PINS: a successful mutation must defer pruning until full publication")
        #expect(
            fixture.index.merge([inventoryCoordinate("c")]).map(\.uid) == [inventoryUID("c")],
            "M684_UNKNOWN_PRESERVES_ALLOWLIST: unknown reconciliation must not install the album allow-list")

        await fixture.timeline.select(.all)
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        // Await the same complete-publication entry wired from MainView's location observer.
        let completedBeforeFull = fixture.events.completedCrawls
        await fixture.publish(fixture.timeline.wholeLibraryItemsForLocations)
        await fixture.finishAdmittedCrawl(after: completedBeforeFull)
        #expect(await fixture.repository.fullReads == 2, "Only explicit All Photos adds a complete listing")
        #expect(
            fixture.persistedUIDs().contains(inventoryUID("b")),
            "M684_FULL_PRESERVES_FOREIGN_PIN: All Photos must retain the photo outside the album")
        #expect(
            !fixture.persistedUIDs().contains(inventoryUID("d")),
            "M684_FULL_CONSUMES_DEFERRED: full publication must consume the earlier successful mutation")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownToKnownEmptyReleasesDeferredReconciliation() async throws {
        let fixture = try await LocationInventoryFixture.make(items: [])
        fixture.seed(["b"])
        await fixture.timeline.load()
        #expect(
            fixture.timeline.wholeLibraryLocationRevision == nil,
            "M684_UNKNOWN_READINESS: missing canonical content has no location revision")
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs() == [inventoryUID("b")],
            "M684_UNKNOWN_EMPTY_PRESERVES: an unknown inventory is not known-empty")

        let changes = InventoryCounter()
        withObservationTracking {
            _ = fixture.timeline.wholeLibraryLocationRevision
        } onChange: {
            changes.increment()
        }
        await fixture.repository.setOnline()
        await fixture.timeline.retry()
        #expect(fixture.timeline.wholeLibraryContentRevision == 0)
        #expect(fixture.timeline.wholeLibraryItemsForLocations == [])
        #expect(fixture.timeline.wholeLibraryLocationRevision == .some(0))
        #expect(
            changes.value == 1,
            "M684_FIRST_EMPTY_NOTIFIES: nil to some(0) must notify the actual readiness observer")
        await fixture.publish(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs().isEmpty,
            "M684_EMPTY_CONSUMES_DEFERRED: complete empty publication reconciles even without a crawl")
        #expect(fixture.probes.values.isEmpty)
        #expect(fixture.session.startingTask == nil)
        #expect(await fixture.repository.fullReads == 2)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [[String](), ["a"]])
    func aCachedSnapshotStaysUnknownUntilAWholeLibraryLoadSucceeds(cachedIDs: [String]) async throws {
        let fixture = try await LocationInventoryFixture.make(cached: cachedIDs.map(inventoryItem))
        fixture.seed(["b", "d"])
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .cached)
        #expect(
            fixture.timeline.wholeLibraryItemsForViewer.map(\.uid) == cachedIDs.map(inventoryUID),
            "The grid and the viewer keep showing the saved library")
        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == nil,
            "M684_CACHED_UNKNOWN: a saved library whose validation and load failed is not known")
        #expect(fixture.timeline.wholeLibraryLocationRevision == nil)

        // A trash that the server confirmed while the saved library is still unvalidated.
        await fixture.timeline.commitTrash([inventoryItem("d")])
        #expect(fixture.timeline.wholeLibraryItemsForLocations == nil, "A trash keeps a saved library unknown")
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
            "M684_CACHED_PRESERVES_PINS: a saved library must not prune pins")
        await fixture.publish(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(fixture.session.startingTask == nil, "M684_CACHED_NO_START: a saved library must not start GPS")

        await fixture.repository.setOnline()
        await fixture.timeline.retry()
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        #expect(fixture.timeline.wholeLibraryLocationRevision != nil)
        await fixture.publish(fixture.timeline.wholeLibraryItemsForLocations)
        await fixture.finishAdmittedCrawl()
        #expect(
            fixture.persistedUIDs().contains(inventoryUID("b")) && !fixture.persistedUIDs().contains(inventoryUID("d")),
            "M684_CACHED_RELEASES: the successful load releases the waiting reconciliation")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRestoreRestartsAScanThatRanBefore() async throws {
        let fixture = try await LocationInventoryFixture.make()
        await fixture.publish(fixture.items)
        await fixture.finishAdmittedCrawl()
        let firstStarter = fixture.session.startingTask
        let completedBefore = fixture.events.completedCrawls
        #expect(firstStarter != nil)

        await fixture.reconcile(fixture.items, restoring: true)

        let restarted = fixture.session.startingTask != firstStarter
        #expect(restarted, "M684_RESTORE_RESTARTS: a restore must start the scan again when it ran before")
        // Wait only for a crawl that was admitted; an unbounded wait would outlive the test's time limit.
        if restarted { await fixture.finishAdmittedCrawl(after: completedBefore) }
        #expect(fixture.session.isStarted)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeferredRestoreSurvivesALaterTrashAndRestartsOnPublication() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let gate = InventoryGate()
        defer { gate.open() }
        fixture.probeGate = gate
        var events = fixture.events.stream.makeAsyncIterator()
        await fixture.publish(fixture.items)
        guard fixture.session.startingTask != nil else {
            Issue.record("M684_SETUP_SCAN: the known library must start the first scan")
            await fixture.close()
            return
        }
        while await events.next() != .probe {}
        #expect(fixture.index.scanProgress.phase == .scanning, "The first scan is still running")

        // Both requests wait for the whole library: a restore while the scan ran, then a trash.
        await fixture.reconcile(nil, restoring: true)
        await fixture.reconcile(nil)
        let runningStarter = fixture.session.startingTask
        await fixture.publish(fixture.items)

        #expect(
            fixture.session.startingTask != runningStarter,
            "M684_RESTORE_INTENT_MERGED: a later trash must keep the waiting restore's restart")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRestoreDuringAFullLoadKeepsTheNewerLibraryForLocations() async throws {
        let restored = inventoryItem("b")
        let fixture = try await LocationInventoryFixture.make(
            items: [inventoryItem("a"), inventoryItem("c")], online: true)
        await fixture.timeline.load()
        fixture.seed(["a", "b", "c"])
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let reload = Task { await fixture.timeline.retry() }
        while await events.next() != .fullReadEntered {}

        // The server listing was read before this restore, so it does not contain the restored photo.
        await fixture.timeline.commitRestore([restored])
        let revisionAfterRestore = fixture.timeline.wholeLibraryLocationRevision
        #expect(fixture.timeline.wholeLibraryItemsForLocations?.contains(restored) == true)
        gate.open()
        await reload.value

        #expect(
            fixture.timeline.wholeLibraryLocationRevision == revisionAfterRestore,
            "M684_STALE_LOAD_REVISION: the older listing must not become the location library")
        #expect(
            fixture.timeline.wholeLibraryItemsForLocations?.contains(restored) == true,
            "M684_STALE_LOAD_ITEMS: the restored photo must stay in the location library")
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs().contains(inventoryUID("b")),
            "M684_STALE_LOAD_PINS: the restored photo's pin must stay")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledFullLoadDoesNotMakeTheLibraryKnown() async throws {
        let fixture = try await LocationInventoryFixture.make()
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryItemsForLocations == nil)
        await fixture.repository.setOnline()
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let reload = Task { await fixture.timeline.retry() }
        while await events.next() != .fullReadEntered {}
        reload.cancel()
        gate.open()
        await reload.value

        #expect(
            fixture.timeline.wholeLibraryLocationRevision == nil,
            "M684_CANCELLED_LOAD: a cancelled load must not make the library known")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == nil)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aConfirmedSavedLibraryIsKnownWithoutAFullListing() async throws {
        let fixture = try await LocationInventoryFixture.make(
            online: true, cached: [inventoryItem("a"), inventoryItem("b"), inventoryItem("c")], cachedToken: "current")
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        #expect(
            fixture.timeline.wholeLibraryLocationRevision != nil,
            "M684_VALIDATED_READY: a confirmed saved library is known for location work")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        #expect(await fixture.repository.fullReads == 0, "The confirmed saved library needs no full listing")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [["a", "b", "c"], ["a"]])
    func aSuccessfulRefreshMakesASavedLibraryKnown(cachedIDs: [String]) async throws {
        let fixture = try await LocationInventoryFixture.make(cached: cachedIDs.map(inventoryItem))
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryLocationRevision == nil)
        await fixture.repository.setOnline()
        await fixture.timeline.refreshLibrary()
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        #expect(
            fixture.timeline.wholeLibraryLocationRevision != nil,
            "M684_REFRESH_READY: a refresh of All Photos makes the library known, unchanged or changed")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        await fixture.close()
    }

    /// Server library and saved library: a stale saved library, an equal one, and an empty library on both sides.
    @Test(
        .timeLimit(.minutes(1)), arguments: [(["a", "b", "c"], ["a"]), (["a", "b", "c"], ["a", "b", "c"]), ([], [])])
    func aSavedLibraryReadOvertakenByARefreshDoesNotReplaceTheKnownLibrary(
        serverIDs: [String], cachedIDs: [String]
    ) async throws {
        let fixture = try await LocationInventoryFixture.make(
            items: serverIDs.map(inventoryItem), online: true, cached: cachedIDs.map(inventoryItem))
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextCacheRead(gate) { fixture.events.send(.cacheReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .cacheReadEntered {}

        await fixture.timeline.refreshLibrary()
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        let knownRevision = fixture.timeline.wholeLibraryLocationRevision
        #expect(knownRevision != nil)
        // The first load's check and full listing fail after the saved library arrives.
        await fixture.repository.setOffline()
        gate.open()
        await loading.value

        #expect(
            fixture.timeline.wholeLibraryInventoryAuthority == .authoritative,
            "M684_CACHE_OVERTAKEN_AUTHORITY: a late saved library must not lower the authority")
        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == fixture.items,
            "M684_CACHE_OVERTAKEN_ITEMS: a late saved library must not replace the known library")
        #expect(fixture.timeline.wholeLibraryLocationRevision == knownRevision)
        #expect(fixture.timeline.allItems == fixture.items, "The grid keeps the newer library")
        #expect(fixture.timeline.initialLibraryChangeToken == "", "A dropped first load leaves the refresh seed")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFullListingHeldAcrossARouteSwitchKeepsTheAlbum() async throws {
        let fixture = try await LocationInventoryFixture.make(online: true)
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .fullReadEntered {}
        await fixture.timeline.select(LocationInventoryRepository.album)
        gate.open()
        await loading.value

        #expect(fixture.timeline.filter == LocationInventoryRepository.album)
        #expect(
            fixture.timeline.allItems.map(\.uid) == [inventoryUID("a")],
            "M684_ROUTE_SWITCH_GRID: the whole library must not replace the open album")
        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == fixture.items,
            "M799_FULL_LISTING_SETTLES: the listing is the whole library although the album is shown")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlbumRoundTripDoesNotDropTheFirstListing() async throws {
        let fixture = try await LocationInventoryFixture.make(online: true)
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .fullReadEntered {}
        await fixture.timeline.select(LocationInventoryRepository.album)
        // Back to All Photos; this second listing fails.
        await fixture.repository.failNextFullReads(1)
        await fixture.timeline.select(.all)
        gate.open()
        await loading.value

        #expect(
            fixture.timeline.allItems == fixture.items,
            "M684_ROUND_TRIP_GRID: All Photos must show the whole library, not the album")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anEmptyLibraryStopsAWaitingScanOfTheOlderLibrary() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let release = InventoryGate()
        defer { release.open() }
        let prerequisite = Task { await release.wait() }
        await fixture.publish(fixture.items, awaiting: prerequisite)
        let waiting = fixture.session.startingTask
        #expect(waiting != nil)
        await fixture.publish([])
        release.open()
        await prerequisite.value
        await waiting?.value

        #expect(
            fixture.session.crawlStartsForTesting == 0,
            "M684_EMPTY_STOPS_WAITING_SCAN: an empty library must stop the waiting scan of the older library")
        #expect(fixture.probes.values.isEmpty)
        #expect(!fixture.session.isStarted)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anEmptyLibraryStopsARunningScan() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let gate = InventoryGate()
        defer { gate.open() }
        fixture.probeGate = gate
        var events = fixture.events.stream.makeAsyncIterator()
        await fixture.publish(fixture.items)
        while await events.next() != .probe {}

        await fixture.publish([])
        // Bound the failure path: without the stop, the held probe is released after ten seconds.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            gate.open()
        }
        var outcome: InventoryEvent?
        while outcome == nil, let event = await events.next() {
            if event == .probeCancelled || event == .probeReleased { outcome = event }
        }
        deadline.cancel()
        #expect(
            outcome == .probeCancelled,
            "M684_EMPTY_STOPS_RUNNING_SCAN: an empty library must stop the crawl of the older library")
        #expect(!fixture.session.isStarted)
        await fixture.session.stoppingTask?.value
        #expect(
            fixture.index.scanProgress.phase == .completed,
            "M801_EMPTY_NOT_SCANNING: the empty Map must not keep showing that it is scanning")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anEmptyLibraryKeepsAFailedScanState() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.index.updateScanProgress(
            PhotoLocationScanProgress(phase: .failed, scanned: 2, total: 3, found: 0, noLocation: 0, failed: 2))
        await fixture.publish([])
        await fixture.session.stoppingTask?.value
        #expect(
            fixture.index.scanProgress.phase == .failed,
            "M801_EMPTY_KEEPS_FAILED: only a scan that the stop cut short is settled")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aLibraryThatBecomesNonEmptyWhileTheStopIsPendingStartsOneScan() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let gate = InventoryGate()
        defer { gate.open() }
        fixture.probeGate = gate
        var events = fixture.events.stream.makeAsyncIterator()
        await fixture.publish(fixture.items)
        while await events.next() != .probe {}
        let startsBefore = fixture.session.crawlStartsForTesting

        await fixture.publish([])
        await fixture.publish(fixture.items)
        await fixture.finishAdmittedCrawl()

        #expect(
            fixture.session.crawlStartsForTesting == startsBefore + 1,
            "M801_EMPTY_THEN_FULL_ONE_SCAN: exactly one scan starts after the stop")
        #expect(fixture.index.scanProgress.phase == .completed)
        #expect(fixture.index.scanProgress.total == fixture.items.count)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aWaitingScanProbesTheNewestLibraryNotTheOneItWasStartedWith() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let release = InventoryGate()
        defer { release.open() }
        let prerequisite = Task { await release.wait() }
        await fixture.publish(fixture.items, awaiting: prerequisite)
        #expect(fixture.session.startingTask != nil)
        // A newer publication removed b and c while the scan waits for its start.
        await fixture.publish([inventoryItem("a")])
        release.open()
        await prerequisite.value
        await fixture.finishAdmittedCrawl()

        #expect(
            Set(fixture.probes.values) == [inventoryUID("a")],
            "M801_WAITING_SCAN_NEWEST: a photo that a newer publication removed must not be probed")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCleanUpThatWaitsSurvivesAReconfigurationOfTheSameAccount() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.seed(["b", "d"])
        fixture.mapSwitch.isOn = false
        await fixture.reconcile(nil)
        // The same account is configured again: the connection is rebuilt.
        _ = fixture.session.invalidate()
        fixture.configurationGeneration += 1
        await fixture.publish(fixture.items)
        #expect(
            fixture.persistedUIDs() == [inventoryUID("b")],
            "M801_RECONFIGURE_KEEPS_CLEANUP: the waiting clean-up must still remove d's pin")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCleanUpThatWaitsIsDroppedForAnotherAccountAndForATeardown() async throws {
        let otherAccount = try await LocationInventoryFixture.make()
        otherAccount.seed(["b", "d"])
        otherAccount.mapSwitch.isOn = false
        await otherAccount.reconcile(nil)
        _ = otherAccount.session.invalidate()
        otherAccount.accountUID = "other"
        await otherAccount.publish(otherAccount.items)
        #expect(
            otherAccount.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
            "M801_OTHER_ACCOUNT_DROPS_CLEANUP: a clean-up of another account must not prune this account")
        // The first account comes back: the clean-up was discarded by the other account's publication, so nothing runs.
        otherAccount.accountUID = "inventory"
        await otherAccount.publish(otherAccount.items)
        #expect(
            otherAccount.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
            "M801_OTHER_ACCOUNT_DISCARDS_CLEANUP: the discarded clean-up must not run for the first account later")
        await otherAccount.close()

        let teardown = try await LocationInventoryFixture.make()
        teardown.seed(["b", "d"])
        teardown.mapSwitch.isOn = false
        await teardown.reconcile(nil)
        _ = teardown.session.retire()
        await teardown.publish(teardown.items)
        #expect(
            teardown.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
            "M801_TEARDOWN_DROPS_CLEANUP: a sign-out drops the waiting clean-up")
        await teardown.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDelayedStartCannotUndoACleanUpThatCompletedBeforeIt() async throws {
        let fixture = try await LocationInventoryFixture.make()
        let release = InventoryGate()
        defer { release.open() }
        let prerequisite = Task { await release.wait() }
        await fixture.publish(fixture.items, awaiting: prerequisite)
        #expect(fixture.session.startingTask != nil)
        // A trash of b completes its clean-up while the scan still waits with the older list [a, b, c].
        await fixture.reconcile([inventoryItem("a"), inventoryItem("c")])
        release.open()
        await prerequisite.value
        await fixture.finishAdmittedCrawl()

        #expect(
            fixture.probes.values.contains(inventoryUID("b")),
            "SETUP: the waiting scan still probes the list it read")
        #expect(
            !fixture.persistedUIDs().contains(inventoryUID("b")),
            "M801_DELAYED_START_KEEPS_CLEANUP: a list that is older than the clean-up must not bring b's pin back")
        #expect(fixture.persistedUIDs().contains(inventoryUID("a")))
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRunningScanStoresAPhotoThatANewPublicationAddsAfterACleanUp() async throws {
        let fixture = try await LocationInventoryFixture.make()
        // A clean-up restricted what the index accepts to a.
        await fixture.reconcile([inventoryItem("a")])
        let gate = InventoryGate()
        defer { gate.open() }
        fixture.probeGate = gate
        var events = fixture.events.stream.makeAsyncIterator()
        await fixture.publish([inventoryItem("a")])
        while await events.next() != .probe {}

        // Photo b arrives while the scan of [a] runs.
        await fixture.publish([inventoryItem("a"), inventoryItem("b")])
        gate.open()
        await fixture.finishAdmittedCrawl()

        #expect(fixture.probes.values.contains(inventoryUID("b")), "SETUP: the running scan reads the new list")
        #expect(
            fixture.persistedUIDs().contains(inventoryUID("b")),
            "M801_RUNNING_SCAN_ACCEPTS_NEW_PHOTO: the index must accept the photo that the running scan probes")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aPublicationWithMapAndPlacesOffReconcilesWithoutScanning() async throws {
        let fixture = try await LocationInventoryFixture.make()
        fixture.seed(["b", "d"])
        await fixture.reconcile(nil)
        fixture.mapSwitch.isOn = false
        await fixture.publish(fixture.items)
        #expect(fixture.persistedUIDs() == [inventoryUID("b")], "The waiting clean-up still runs")
        #expect(
            fixture.session.startingTask == nil && fixture.probes.values.isEmpty,
            "M684_MAP_OFF_NO_SCAN: no scan starts while Map and Places is off")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRestoreBeforeTheFirstSnapshotDropsTheOlderFirstListing() async throws {
        let restored = inventoryItem("b")
        let fixture = try await LocationInventoryFixture.make(
            items: [inventoryItem("a"), inventoryItem("c")], online: true)
        fixture.seed(["a", "b", "c"])
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .fullReadEntered {}

        // No whole-library snapshot exists yet; the listing was read before this restore.
        await fixture.timeline.commitRestore([restored])
        gate.open()
        await loading.value

        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == nil,
            "M684_RESTORE_BEFORE_SNAPSHOT: the older first listing must not become the location library")
        #expect(fixture.timeline.initialLibraryChangeToken == "", "The change check refreshes the library")
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(fixture.persistedUIDs().contains(inventoryUID("b")), "The restored photo's pin must stay")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshOvertakenByARestoreIsRejected() async throws {
        let restored = inventoryItem("b")
        let fixture = try await LocationInventoryFixture.make(
            items: [inventoryItem("a"), inventoryItem("c")], online: true)
        await fixture.timeline.load()
        fixture.seed(["a", "b", "c"])
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let refresh = Task { await fixture.timeline.refreshLibrary() }
        while await events.next() != .fullReadEntered {}

        await fixture.timeline.commitRestore([restored])
        let known = fixture.timeline.wholeLibraryItemsForLocations
        gate.open()
        let result = await refresh.value

        #expect(
            result.failureReason == .superseded,
            "M798_OVERTAKEN_REFRESH_REJECTED: the refresh read before the restore must not replace the snapshot")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == known)
        #expect(fixture.timeline.wholeLibraryItemsForLocations?.contains(restored) == true)
        #expect(fixture.timeline.allItems.contains(restored), "The grid keeps the restored photo")
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(
            fixture.persistedUIDs().contains(inventoryUID("b")),
            "M798_OVERTAKEN_REFRESH_PINS: the restored photo's pin must stay")

        // A refresh that nothing overtakes still applies.
        await fixture.repository.setItems([inventoryItem("a"), restored])
        let applied = await fixture.timeline.refreshLibrary()
        #expect(applied.failureReason == nil)
        #expect(fixture.timeline.wholeLibraryItemsForLocations == [inventoryItem("a"), restored])
        await fixture.reconcile(fixture.timeline.wholeLibraryItemsForLocations)
        #expect(!fixture.persistedUIDs().contains(inventoryUID("c")), "The clean-up of the applied list removes c")
        #expect(fixture.persistedUIDs().contains(inventoryUID("b")))
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshOvertakenByATrashIsRejectedEvenWhenItsListEqualsTheGrid() async throws {
        let fixture = try await LocationInventoryFixture.make(
            items: [inventoryItem("a"), inventoryItem("c")], online: true)
        await fixture.timeline.load()
        // The server list already lacks c, as the grid will after the trash: the refresh finds nothing to change.
        await fixture.repository.setItems([inventoryItem("a")])
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let refresh = Task { await fixture.timeline.refreshLibrary() }
        while await events.next() != .fullReadEntered {}

        await fixture.timeline.commitTrash([inventoryItem("c")])
        gate.open()
        let result = await refresh.value

        #expect(
            result.failureReason == .superseded,
            "M801_OVERTAKEN_UNCHANGED_REJECTED: an equal list that a trash overtook acknowledges no revision")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == [inventoryItem("a")])
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSavedLibraryConfirmedDuringARouteSwitchIsKnown() async throws {
        let fixture = try await LocationInventoryFixture.make(
            online: true, cached: [inventoryItem("a"), inventoryItem("b"), inventoryItem("c")], cachedToken: "current")
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextTokenProbe(gate) { fixture.events.send(.tokenProbeEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .tokenProbeEntered {}
        await fixture.timeline.select(LocationInventoryRepository.album)
        gate.open()
        await loading.value

        #expect(fixture.timeline.filter == LocationInventoryRepository.album)
        #expect(
            fixture.timeline.allItems.map(\.uid) == [inventoryUID("a")],
            "M799_GRID_KEEPS_ALBUM: the saved library must not replace the open album")
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == fixture.items,
            "M799_CONFIRMED_SETTLES: a saved library the check proved current is known for location work")
        #expect(await fixture.repository.fullReads == 0, "Settling adds no request")
        // Back to All Photos shows the library.
        await fixture.timeline.select(.all)
        #expect(fixture.timeline.allItems == fixture.items)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRouteSwitchBeforeTheSavedLibraryIsReadProvesNothing() async throws {
        let fixture = try await LocationInventoryFixture.make(
            online: true, cached: [inventoryItem("a"), inventoryItem("b"), inventoryItem("c")], cachedToken: "current")
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextCacheRead(gate) { fixture.events.send(.cacheReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .cacheReadEntered {}
        await fixture.timeline.select(LocationInventoryRepository.album)
        gate.open()
        await loading.value

        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == nil,
            "M799_NO_PROOF: nothing was confirmed, so the library stays unknown")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSavedLibraryThatATrashOvertookStaysUnknownAfterARouteSwitch() async throws {
        let fixture = try await LocationInventoryFixture.make(
            online: true, cached: [inventoryItem("a"), inventoryItem("b"), inventoryItem("c")], cachedToken: "current")
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextTokenProbe(gate) { fixture.events.send(.tokenProbeEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let loading = Task { await fixture.timeline.load() }
        while await events.next() != .tokenProbeEntered {}
        await fixture.timeline.select(LocationInventoryRepository.album)
        await fixture.timeline.commitTrash([inventoryItem("c")])
        gate.open()
        await loading.value

        #expect(
            fixture.timeline.wholeLibraryItemsForLocations == nil,
            "M799_OVERTAKEN_STAYS_UNKNOWN: a trash during the check means the confirmed list is not current")
        await fixture.close()
    }
    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func aTrashProjectionThatAReloadOvertookRunsAgainOnTheNewerLibrary() async throws {
            // The saved library [a, c]; the server library is [a, b].
            let fixture = try await LocationInventoryFixture.make(
                items: [inventoryItem("a"), inventoryItem("b")], online: true,
                cached: [inventoryItem("a"), inventoryItem("c")], cachedToken: "saved")
            fixture.seed(["a", "b", "c"])
            let probeGate = InventoryGate()
            let projectionGate = InventoryGate()
            let fullReadGate = InventoryGate()
            defer {
                probeGate.open()
                projectionGate.open()
                fullReadGate.open()
            }
            var events = fixture.events.stream.makeAsyncIterator()
            await fixture.repository.holdNextTokenProbe(probeGate) { fixture.events.send(.tokenProbeEntered) }
            let loading = Task { await fixture.timeline.load() }
            while await events.next() != .tokenProbeEntered {}

            // The trash of c commits and its projection computed [a] from the saved library; it waits before it writes.
            var held = true
            fixture.timeline.afterProjectionComputedForTesting = {
                guard held else { return }
                held = false
                fixture.events.send(.projectionEntered)
                await projectionGate.wait()
            }
            let trash = Task { await fixture.timeline.commitTrash([inventoryItem("c")]) }
            while await events.next() != .projectionEntered {}
            // The first load straddled the trash. It is dropped and leaves the saved library as it was.
            probeGate.open()
            await loading.value
            #expect(fixture.timeline.wholeLibraryItemsForLocations == nil)

            // A reload of All Photos starts after the trash was counted and reads [a, b]. The person opens an album
            // before it finishes, so the result is settled for the whole library without touching the grid.
            await fixture.timeline.select(LocationInventoryRepository.album)
            await fixture.repository.holdNextFullRead(fullReadGate) { fixture.events.send(.fullReadEntered) }
            let reload = Task { await fixture.timeline.select(.all) }
            while await events.next() != .fullReadEntered {}
            await fixture.timeline.select(LocationInventoryRepository.album)
            fullReadGate.open()
            await reload.value
            #expect(fixture.timeline.wholeLibraryItemsForLocations == [inventoryItem("a"), inventoryItem("b")])

            projectionGate.open()
            await trash.value
            let known = fixture.timeline.wholeLibraryItemsForLocations
            #expect(
                known == [inventoryItem("a"), inventoryItem("b")],
                "M801_OLDER_PROJECTION_RERUNS: the older projection must not overwrite the newer library")
            await fixture.reconcile(known)
            #expect(
                fixture.persistedUIDs().contains(inventoryUID("b")),
                "M801_OLDER_PROJECTION_PINS: the clean-up must not remove the pin of b")
            #expect(!fixture.persistedUIDs().contains(inventoryUID("c")))
            await fixture.close()
        }

    #endif

    @Test(.timeLimit(.minutes(1)))
    func aRefreshThatAnEqualNewerListingOvertookIsRejected() async throws {
        let fixture = try await LocationInventoryFixture.make(
            items: [inventoryItem("a"), inventoryItem("b")], online: true)
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        // The refresh reads an older server state [a] and waits.
        await fixture.repository.setItems([inventoryItem("a")])
        let gate = InventoryGate()
        defer { gate.open() }
        await fixture.repository.holdNextFullRead(gate) { fixture.events.send(.fullReadEntered) }
        var events = fixture.events.stream.makeAsyncIterator()
        let refresh = Task { await fixture.timeline.refreshLibrary() }
        while await events.next() != .fullReadEntered {}

        // A newer load of All Photos publishes [a, b] again: the same content and the same authority as before.
        await fixture.repository.setItems(fixture.items)
        await fixture.timeline.select(LocationInventoryRepository.album)
        await fixture.timeline.select(.all)
        gate.open()
        let result = await refresh.value

        #expect(
            result.failureReason == .superseded,
            "M801_EQUAL_NEWER_LISTING: a newer listing with equal content still overtakes an older refresh")
        #expect(fixture.timeline.wholeLibraryItemsForLocations == fixture.items)
        #expect(fixture.timeline.allItems == fixture.items)
        await fixture.close()
    }
}

#if DEBUG

    @Suite @MainActor struct WholeLibraryLocationGuardTests {
        @Test(.timeLimit(.minutes(1)))
        func aPublicationThatLandsDuringTheLastInventoryReadIsTheOneTheScanUses() async throws {
            let fixture = try await LocationInventoryFixture.make()
            let release = InventoryGate()
            defer { release.open() }
            let prerequisite = Task { await release.wait() }
            await fixture.publish(fixture.items, awaiting: prerequisite)
            var replaced = false
            fixture.session.afterInventoryReadForTesting = {
                guard !replaced else { return }
                replaced = true
                // The newer library arrives while the older inventory is still awaited.
                fixture.session.updateInventory([inventoryItem("a")])
            }
            release.open()
            await prerequisite.value
            await fixture.finishAdmittedCrawl()

            #expect(replaced, "SETUP: the hook ran")
            #expect(
                Set(fixture.probes.values) == [inventoryUID("a")],
                "M801_LAST_AWAIT_REVALIDATED: a photo that the newer library lacks must not be probed")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func coalescedUnknownMutationsConsumeOneCompletePublication() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = { projections.increment() }
            for _ in 0..<3 { await fixture.reconcile(nil) }
            #expect(projections.value == 0, "G684_COALESCE_UNKNOWN: unknown mutations must not project")
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_COALESCE_RETAINS: unknown mutations must retain prior disk pins")
            await fixture.publish([])
            #expect(projections.value == 1, "G684_COALESCE_ONCE: one complete publication consumes one pending request")
            #expect(fixture.persistedUIDs().isEmpty, "G684_COALESCE_PERSISTS: the coalesced mutation must persist")
            fixture.seed(["b"])
            await fixture.publish([])
            #expect(projections.value == 1, "G684_CONSUMED_ONCE: later publication must not reconcile consumed work")
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_CONSUMED_RETAINS: publication alone must not repeat a successful mutation")
            #expect(fixture.probes.values.isEmpty)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func newerUnknownMutationRejectsAHeldObsoleteRequest() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let release = InventoryGate()
            defer { release.open() }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                if projections.next() == 1 {
                    fixture.events.send(.projectionEntered)
                    await release.wait()
                }
            }
            let obsolete = Task { await fixture.reconcile([inventoryItem("a")]) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            await fixture.reconcile(nil)
            release.open()
            await obsolete.value
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_REQUEST_DISK: an obsolete request must not prune before current publication")
            #expect(
                Set(fixture.index.coordinates.map(\.uid)) == [inventoryUID("b"), inventoryUID("d")],
                "G684_REQUEST_INDEX: an obsolete request must not replace the current allow-list")
            await fixture.publish([])
            #expect(fixture.persistedUIDs().isEmpty, "G684_REQUEST_CURRENT: the newer pending mutation must survive")
            #expect(projections.value == 2)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func newerPublicationRejectsTheOlderAttemptBeforeConsumption() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let oldRelease = InventoryGate()
            let currentRelease = InventoryGate()
            defer {
                oldRelease.open()
                currentRelease.open()
            }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                let attempt = projections.next()
                fixture.events.send(.projectionEntered)
                if attempt == 1 { await oldRelease.wait() } else { await currentRelease.wait() }
            }
            let older = Task { await fixture.publish([inventoryItem("a")]) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            let current = Task { await fixture.publish([]) }
            #expect(await events.next() == .projectionEntered)
            oldRelease.open()
            await older.value
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_ATTEMPT_DISK: an obsolete attempt must not prune while the current attempt is held")
            #expect(
                Set(fixture.index.coordinates.map(\.uid)) == [inventoryUID("b"), inventoryUID("d")],
                "G684_ATTEMPT_INDEX: matching request and lease must not admit an older attempt")
            currentRelease.open()
            await current.value
            await fixture.finishAdmittedCrawl()
            #expect(
                fixture.persistedUIDs().isEmpty,
                "G684_ATTEMPT_CURRENT: the current publication must consume pending work")
            #expect(projections.value == 2)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func cancelledCallerCannotReplaceOrConsumeCurrentPending() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let release = InventoryGate()
            let cancelledRelease = InventoryGate()
            defer {
                release.open()
                cancelledRelease.open()
            }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                if projections.next() == 1 {
                    fixture.events.send(.projectionEntered)
                    await release.wait()
                }
            }
            let current = Task { await fixture.publish([inventoryItem("b")]) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            let cancelled = Task {
                await cancelledRelease.wait()
                #expect(Task.isCancelled, "G684_SETUP_CANCELLED: cancellation must precede the public calls")
                await fixture.reconcile(nil)
                await fixture.publish([])
            }
            cancelled.cancel()
            cancelledRelease.open()
            await cancelled.value
            #expect(projections.value == 1, "G684_CANCEL_NO_CONSUME: a cancelled caller must not consume pending work")
            release.open()
            await current.value
            await fixture.finishAdmittedCrawl()
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_CANCEL_CURRENT: cancellation must not replace the admitted current request")
            await fixture.publish([])
            #expect(
                projections.value == 1,
                "G684_CANCEL_NO_REPLACEMENT: cancelled mutation must not leave another request")
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_CANCEL_RETAINS: later publication must preserve already reconciled current pins")

            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let heldRelease = InventoryGate()
            defer { heldRelease.open() }
            let probesBeforeHeldCancellation = fixture.probes.values
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await heldRelease.wait()
            }
            let heldCancelled = Task { await fixture.publish([inventoryItem("a")]) }
            while await events.next() != .projectionEntered {}
            heldCancelled.cancel()
            heldRelease.open()
            await heldCancelled.value
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_CANCEL_HELD_DISK: cancellation during projection must not prune pending disk pins")
            #expect(
                Set(fixture.index.coordinates.map(\.uid)) == [inventoryUID("b"), inventoryUID("d")],
                "G684_CANCEL_HELD_INDEX: cancellation during projection must not install an allow-list")
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = nil
            await fixture.publish([])
            #expect(
                fixture.persistedUIDs().isEmpty,
                "G684_CANCEL_HELD_PENDING: a later current publication must consume uncancelled pending facts")
            #expect(fixture.probes.values == probesBeforeHeldCancellation)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func sameAccountConfigurationFactsRejectWorkBeforeProjection() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let release = InventoryGate()
            defer { release.open() }
            let prerequisite = Task { await release.wait() }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                projections.increment()
                fixture.events.send(.projectionEntered)
            }
            let owner = Task {
                await fixture.session.reconcileWholeLibrary(
                    items: [inventoryItem("a")], recrawlRestoredItems: false,
                    owner: fixture.session.captureOwnerLease(),
                    isCurrent: { fixture.currentAccount },
                    makeStart: {
                        let start = fixture.makeStart(awaiting: prerequisite)
                        fixture.events.send(.factsCaptured)
                        return start
                    })
                fixture.events.send(.ownerFinished)
            }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .factsCaptured)
            fixture.configurationGeneration &+= 1
            release.open()
            #expect(
                await events.next() == .ownerFinished,
                "G684_CONFIG_BEFORE_PROJECTION: obsolete same-account facts must finish before worker entry")
            await owner.value
            await prerequisite.value
            #expect(
                projections.value == 0,
                "G684_CONFIG_NO_PROJECTION: a current store lease cannot admit stale configuration facts")
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_CONFIG_DISK: stale configuration facts must preserve prior disk pins")
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = nil
            fixture.seed(["b", "d"])
            await fixture.reconcile([inventoryItem("b")])
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_CONFIG_CURRENT: current same-account facts must reconcile")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func pauseDuringHeldRestoreReconcilesDataWithoutRestartingGPS() async throws {
            let fixture = try await LocationInventoryFixture.make()
            await fixture.publish(fixture.items)
            await fixture.finishAdmittedCrawl()
            #expect(fixture.session.isStarted)
            fixture.seed(["b", "d"])
            let probesBefore = fixture.probes.values
            let completedBefore = fixture.events.completedCrawls
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            let owner = Task { await fixture.reconcile([inventoryItem("b")], restoring: true) }
            var events = fixture.events.stream.makeAsyncIterator()
            while await events.next() != .projectionEntered {}
            fixture.session.pause()
            release.open()
            await owner.value
            #expect(
                !fixture.session.isStarted,
                "G684_PAUSE_NO_RESTART: restore completion must not reactivate paused GPS")
            if fixture.session.isStarted { await fixture.finishAdmittedCrawl(after: completedBefore) }
            await fixture.session.startingTask?.value
            await fixture.session.crawl.cancel()
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_PAUSE_DATA: pause must keep same-account reconciliation")
            #expect(
                fixture.probes.values == probesBefore,
                "G684_PAUSE_NO_PROBE: restore completion must not add a GPS probe after pause")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func workThatStartsAfterAReconfigurationCannotTouchTheCurrentOwner() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = { projections.increment() }
            // A trash and a publication of the earlier configuration capture their owner, then wait.
            let earlierOwner = fixture.session.captureOwnerLease()
            // The account is configured again. Everything else stays current: account check, start facts and
            // store session, so only the owner can reject the late work.
            _ = fixture.session.invalidate()
            await fixture.reconcile(nil)

            await fixture.reconcile([inventoryItem("a")], owner: earlierOwner)
            await fixture.publish([inventoryItem("a")], owner: earlierOwner)

            #expect(projections.value == 0, "G684_OWNER_NO_PROJECTION: earlier work must not project")
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_OWNER_PINS: earlier work must not prune the current owner's pins")
            #expect(fixture.session.startingTask == nil, "G684_OWNER_NO_START: earlier work must not start GPS")
            await fixture.publish([inventoryItem("b")])
            #expect(projections.value == 1)
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b")],
                "G684_OWNER_PENDING_KEPT: the current owner's waiting reconciliation must survive")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func anAdmittedRequestHeldAcrossAReconfigurationIsRejected() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            let owner = Task { await fixture.reconcile([inventoryItem("a")]) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            // Only the configuration changes; the account check, start facts and store session stay current.
            _ = fixture.session.invalidate()
            release.open()
            await owner.value
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_HELD_RECONFIGURED: a request admitted before a configuration must not prune after it")
            #expect(Set(fixture.index.coordinates.map(\.uid)) == [inventoryUID("b"), inventoryUID("d")])
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aReconciliationThatTakesOverAPublicationStartsTheScan() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let release = InventoryGate()
            defer { release.open() }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                if projections.next() == 1 {
                    fixture.events.send(.projectionEntered)
                    await release.wait()
                }
            }
            let publication = Task { await fixture.publish(fixture.items) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            // A trash with the known library takes over the publication's waiting reconciliation.
            await fixture.reconcile([inventoryItem("a"), inventoryItem("b")])
            release.open()
            await publication.value

            #expect(projections.value == 2)
            #expect(fixture.persistedUIDs() == [inventoryUID("b")])
            #expect(
                fixture.session.startingTask != nil && fixture.session.isStarted,
                "G684_TAKEOVER_STARTS: the takeover must start the scan that the publication still owed")
            await fixture.finishAdmittedCrawl()
            #expect(fixture.session.crawlStartsForTesting == 1, "G684_TAKEOVER_ONE_START: exactly one scan starts")
            #expect(!fixture.probes.values.isEmpty)
            #expect(
                !fixture.probes.values.contains(inventoryUID("c")),
                "G684_TAKEOVER_NEWER_ITEMS: the scan uses the takeover's newer library, not the older publication's")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aCancelledTakeoverStillStartsTheOwedScanOnce() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let publicationRelease = InventoryGate()
            let takeoverRelease = InventoryGate()
            defer {
                publicationRelease.open()
                takeoverRelease.open()
            }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                let attempt = projections.next()
                fixture.events.send(.projectionEntered)
                if attempt == 1 { await publicationRelease.wait() } else { await takeoverRelease.wait() }
            }
            let publication = Task { await fixture.publish(fixture.items) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            let takeover = Task { await fixture.reconcile([inventoryItem("a"), inventoryItem("b")]) }
            #expect(await events.next() == .projectionEntered)
            takeover.cancel()
            takeoverRelease.open()
            await takeover.value
            publicationRelease.open()
            await publication.value

            #expect(projections.value == 2)
            #expect(
                fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")],
                "G684_CANCELLED_TAKEOVER_PENDING: the cancelled request must leave the waiting work")
            #expect(
                fixture.session.startingTask != nil,
                "G684_CANCELLED_TAKEOVER_STARTS: the cancelled taker must not drop the owed scan start")
            await fixture.finishAdmittedCrawl()
            #expect(fixture.session.crawlStartsForTesting == 1, "G684_CANCELLED_TAKEOVER_ONE_START")
            #expect(!fixture.probes.values.contains(inventoryUID("c")))
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aSupersededTakeoverLeavesTheStartToTheNewerPublication() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let releases = [InventoryGate(), InventoryGate(), InventoryGate()]
            defer { releases.forEach { $0.open() } }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                let attempt = projections.next()
                fixture.events.send(.projectionEntered)
                await releases[min(attempt, 3) - 1].wait()
            }
            var events = fixture.events.stream.makeAsyncIterator()
            let older = Task { await fixture.publish(fixture.items) }
            #expect(await events.next() == .projectionEntered)
            let takeover = Task { await fixture.reconcile([inventoryItem("a"), inventoryItem("b")]) }
            #expect(await events.next() == .projectionEntered)
            // The library became empty; this newer publication takes over the waiting work from the request.
            let newer = Task { await fixture.publish([]) }
            #expect(await events.next() == .projectionEntered)
            releases[1].open()
            await takeover.value
            releases[2].open()
            await newer.value
            releases[0].open()
            await older.value

            #expect(fixture.persistedUIDs().isEmpty, "The newer, empty publication reconciles the pins")
            #expect(
                fixture.session.startingTask == nil,
                "G684_SUPERSEDED_NO_START: a superseded request must not start a scan over its older library")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func anOwedScanAcceptsPhotosThatAnEarlierCleanUpExcluded() async throws {
            let fixture = try await LocationInventoryFixture.make()
            // An earlier clean-up made the index accept only a and c.
            await fixture.reconcile([inventoryItem("a"), inventoryItem("c")])
            await fixture.reconcile(nil)
            let publicationRelease = InventoryGate()
            let takeoverRelease = InventoryGate()
            defer {
                publicationRelease.open()
                takeoverRelease.open()
            }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                let attempt = projections.next()
                fixture.events.send(.projectionEntered)
                if attempt == 1 { await publicationRelease.wait() } else { await takeoverRelease.wait() }
            }
            let publication = Task { await fixture.publish(fixture.items) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            // Photo b was restored; its clean-up takes over and is cancelled before it reconciles.
            let takeover = Task { await fixture.reconcile(fixture.items, restoring: true) }
            #expect(await events.next() == .projectionEntered)
            takeover.cancel()
            takeoverRelease.open()
            await takeover.value
            publicationRelease.open()
            await publication.value
            await fixture.finishAdmittedCrawl()

            #expect(fixture.session.crawlStartsForTesting == 1)
            #expect(fixture.probes.values.contains(inventoryUID("b")))
            #expect(
                fixture.persistedUIDs().contains(inventoryUID("b")),
                "G684_SCAN_ACCEPTS_LIBRARY: the scan must keep the pin of a photo the earlier clean-up excluded")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aTakerThatIsNoLongerCurrentLeavesTheOwedStartForThePublication() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let publicationRelease = InventoryGate()
            let takeoverRelease = InventoryGate()
            defer {
                publicationRelease.open()
                takeoverRelease.open()
            }
            let projections = InventoryCounter()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                let attempt = projections.next()
                fixture.events.send(.projectionEntered)
                if attempt == 1 {
                    await publicationRelease.wait()
                } else if attempt == 2 {
                    await takeoverRelease.wait()
                }
            }
            let publication = Task { await fixture.publish(fixture.items) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            let takeover = Task { await fixture.reconcile([inventoryItem("a"), inventoryItem("b")]) }
            #expect(await events.next() == .projectionEntered)
            fixture.currentAccount = false
            takeoverRelease.open()
            await takeover.value
            publicationRelease.open()
            await publication.value
            #expect(
                fixture.session.startingTask == nil,
                "G684_NOT_CURRENT_NO_START: a taker that is no longer current must not start the scan")
            #expect(fixture.persistedUIDs() == [inventoryUID("b"), inventoryUID("d")])

            fixture.currentAccount = true
            await fixture.publish(fixture.items)
            await fixture.finishAdmittedCrawl()
            #expect(fixture.session.crawlStartsForTesting == 1, "The next publication starts the scan once")
            #expect(!fixture.persistedUIDs().contains(inventoryUID("d")))
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aCancelledRestoreLeavesItsRestartToTheNextPublication() async throws {
            let fixture = try await LocationInventoryFixture.make()
            await fixture.publish(fixture.items)
            await fixture.finishAdmittedCrawl()
            let firstStarter = fixture.session.startingTask
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            let restore = Task { await fixture.reconcile(fixture.items, restoring: true) }
            var events = fixture.events.stream.makeAsyncIterator()
            while await events.next() != .projectionEntered {}
            restore.cancel()
            release.open()
            await restore.value
            #expect(
                fixture.session.startingTask == firstStarter,
                "G684_CANCELLED_RESTORE_NO_START: a cancelled restore must not restart the scan itself")

            fixture.session.beforeWholeLibraryUIDProjectionForTesting = nil
            await fixture.publish(fixture.items)
            #expect(
                fixture.session.startingTask != firstStarter,
                "G684_CANCELLED_RESTORE_PENDING: the next publication consumes the restore and restarts the scan")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aNewConfigurationForgetsAnOwedScanStart() async throws {
            let fixture = try await LocationInventoryFixture.make()
            fixture.seed(["b", "d"])
            await fixture.reconcile(nil)
            let release = InventoryGate()
            defer { release.open() }
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = {
                fixture.events.send(.projectionEntered)
                await release.wait()
            }
            // A publication stops while it holds the waiting work; it leaves its scan start owed.
            let publication = Task { await fixture.publish(fixture.items) }
            var events = fixture.events.stream.makeAsyncIterator()
            #expect(await events.next() == .projectionEntered)
            publication.cancel()
            release.open()
            await publication.value
            #expect(fixture.session.startingTask == nil)

            _ = fixture.session.invalidate()
            fixture.session.beforeWholeLibraryUIDProjectionForTesting = nil
            await fixture.reconcile([inventoryItem("a"), inventoryItem("b")])

            #expect(fixture.persistedUIDs() == [inventoryUID("b")])
            #expect(
                fixture.session.startingTask == nil,
                "G684_CONFIG_FORGETS_OWED_START: a start owed by an earlier configuration must not start a scan")
            await fixture.close()
        }
    }
#endif

@MainActor private final class LocationInventoryFixture {
    let directory: URL
    let key = SymmetricKey(size: .bits256)
    let items: [PhotoItem]
    let repository: LocationInventoryRepository
    let feed: ThumbnailFeedCore
    let timeline: TimelineViewModel
    let store: PhotoLocationStore
    let index: PhotoLocationIndex
    let session: LocationCrawlSession
    nonisolated let events = InventoryEvents()
    nonisolated let probes = InventoryProbes()
    /// Map and Places on or off for the session.
    nonisolated let mapSwitch = InventorySwitch()
    var currentAccount = true
    var configurationGeneration: UInt64 = 0
    /// Holds every GPS probe after it was recorded, so a test can act while a crawl scans.
    var probeGate: InventoryGate?
    /// The account that the next start facts belong to.
    var accountUID = "inventory"

    private init(items: [PhotoItem], online: Bool, cached: [PhotoItem]?, cachedToken: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-inventory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.items = items
        repository = LocationInventoryRepository(
            items: items, online: online, cached: cached, cachedToken: cachedToken)
        feed = ThumbnailFeedCore(
            cache: ThumbnailCache(rootDirectory: directory.appendingPathComponent("thumbnails")),
            loader: InventoryThumbnails())
        timeline = TimelineViewModel(repository: repository, feed: feed, library: repository)
        store = PhotoLocationStore(directory: directory.appendingPathComponent("locations"))
        store.configure(accountUID: "inventory", key: key)
        index = PhotoLocationIndex()
        session = LocationCrawlSession(
            platform: .init(headStart: .zero, requiresStoreSession: true),
            index: index, store: store, crawl: LocationCrawl(throttle: .zero),
            isEnabled: { [mapSwitch] in mapSwitch.isOn })
    }

    static func make(
        items: [PhotoItem] = [inventoryItem("a"), inventoryItem("b"), inventoryItem("c")], online: Bool = false,
        cached: [PhotoItem]? = nil, cachedToken: String = "cached"
    ) async throws -> LocationInventoryFixture {
        let fixture = try LocationInventoryFixture(
            items: items, online: online, cached: cached, cachedToken: cachedToken)
        // These tests exercise timeline and location publication. Admit no unrelated thumbnail workers.
        await fixture.feed.setPrefetchEnabled(false)
        return fixture
    }

    func makeStart(awaiting: Task<Void, Never>? = nil) -> LocationCrawlSession.Start {
        let configurationGeneration = configurationGeneration
        let events = events
        let probes = probes
        let probeGate = probeGate
        return .init(
            accountUID: accountUID,
            location: { uid in
                probes.record(uid)
                events.send(.probe)
                if let probeGate {
                    // A cancelled crawl releases its held probe, so a test can see the cancellation.
                    await withTaskCancellationHandler {
                        await probeGate.wait()
                    } onCancel: {
                        probeGate.open()
                    }
                    events.send(Task.isCancelled ? .probeCancelled : .probeReleased)
                }
                return .found(latitude: 10, longitude: 20)
            },
            visibleDemand: { false },
            log: { message in
                if message.hasPrefix("[LocationCrawl] completed") || message.hasPrefix("[LocationCrawl] FAILED") {
                    events.send(.crawlFinished)
                }
            },
            isCurrent: { [weak self] in
                self?.currentAccount == true && self?.configurationGeneration == configurationGeneration
            },
            awaiting: awaiting)
    }

    /// `owner` defaults to the current configuration, captured when the call starts.
    func publish(
        _ items: [PhotoItem]?, awaiting: Task<Void, Never>? = nil, owner: LocationCrawlSession.OwnerLease? = nil
    ) async {
        await session.publishWholeLibrary(
            items: items, owner: owner ?? session.captureOwnerLease(), isCurrent: { self.currentAccount },
            makeStart: { self.makeStart(awaiting: awaiting) })
    }

    func reconcile(
        _ items: [PhotoItem]?, restoring: Bool = false, owner: LocationCrawlSession.OwnerLease? = nil
    ) async {
        await session.reconcileWholeLibrary(
            items: items, recrawlRestoredItems: restoring, owner: owner ?? session.captureOwnerLease(),
            isCurrent: { self.currentAccount }, makeStart: { self.makeStart() })
    }

    func finishAdmittedCrawl(after completedBefore: Int = 0) async {
        guard let starter = session.startingTask else { return }
        await starter.value
        var iterator = events.stream.makeAsyncIterator()
        while events.completedCrawls <= completedBefore {
            _ = await iterator.next()
        }
        #expect(index.scanProgress.phase == .completed, "M684_SETUP_CRAWL: admitted synthetic crawl must complete")
    }

    func seed(_ ids: [String]) {
        let coordinates = ids.map(inventoryCoordinate)
        index.replaceAll(coordinates)
        store.save(coordinates)
    }

    func persistedUIDs(account: String = "inventory", key: SymmetricKey? = nil) -> Set<PhotoUID> {
        let reopened = PhotoLocationStore(directory: directory.appendingPathComponent("locations"))
        reopened.configure(accountUID: account, key: key ?? self.key)
        return Set(reopened.load().map(\.uid))
    }

    func close() async {
        probeGate?.open()
        let retiring = session.retire()
        await retiring?.value
        await session.crawl.cancel()
        #if DEBUG
            session.beforeWholeLibraryUIDProjectionForTesting = nil
        #endif
        // Timeline prefetch starters may still call startPrefetch; disabled admission keeps them harmless.
        await feed.setPrefetchEnabled(false)
        await feed.stopPrefetchAndWait()
        events.finish()
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("M684_SETUP_CLEANUP: isolated fixture removal failed")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path), "M684_SETUP_CLEANUP: fixture must be absent")
    }
}

private actor LocationInventoryRepository: PhotosRepository, PhotoLibraryProvider, LibraryChangeTokenProvider {
    static let album = PhotoFilter.album(id: "album-a", title: "Album A")
    private var items: [PhotoItem]
    private let cached: [PhotoItem]?
    private let cachedToken: String
    private var online: Bool
    private var fullReadGate: InventoryGate?
    private var fullReadEntered: (@Sendable () -> Void)?
    private var cacheReadGate: InventoryGate?
    private var cacheReadEntered: (@Sendable () -> Void)?
    private var tokenProbeGate: InventoryGate?
    private var tokenProbeEntered: (@Sendable () -> Void)?
    private var failingFullReads = 0
    private(set) var fullReads = 0
    private(set) var filteredReads = 0

    init(items: [PhotoItem], online: Bool, cached: [PhotoItem]?, cachedToken: String) {
        self.items = items
        self.online = online
        self.cached = cached
        self.cachedToken = cachedToken
    }

    func setOnline() { online = true }
    func setOffline() { online = false }
    /// The server library changed, for example after a trash.
    func setItems(_ items: [PhotoItem]) { self.items = items }
    /// The next full listings fail as if the server were unreachable.
    func failNextFullReads(_ count: Int) { failingFullReads = count }
    /// Holds the next read of the saved library after it was read, until `gate` opens.
    func holdNextCacheRead(_ gate: InventoryGate, entered: @escaping @Sendable () -> Void) {
        cacheReadGate = gate
        cacheReadEntered = entered
    }
    /// Holds the next validation probe of the saved library, until `gate` opens.
    func holdNextTokenProbe(_ gate: InventoryGate, entered: @escaping @Sendable () -> Void) {
        tokenProbeGate = gate
        tokenProbeEntered = entered
    }
    /// Holds the next full listing after it read the server list, until `gate` opens.
    func holdNextFullRead(_ gate: InventoryGate, entered: @escaping @Sendable () -> Void) {
        fullReadGate = gate
        fullReadEntered = entered
    }
    /// A saved library from an earlier launch. It is validated only when `cachedToken` is the current token.
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        let snapshot = cached.map {
            CachedTimelineSnapshot(sections: inventorySections($0), validationToken: cachedToken)
        }
        if let gate = cacheReadGate {
            cacheReadGate = nil
            cacheReadEntered?()
            await gate.wait()
        }
        return snapshot
    }
    /// The validation probe fails while offline.
    func libraryChangeToken() async throws -> String {
        guard online else { throw InventoryOffline() }
        if let gate = tokenProbeGate {
            tokenProbeGate = nil
            tokenProbeEntered?()
            await gate.wait()
        }
        return "current"
    }
    func loadTimeline() async throws -> [TimelineSection] {
        fullReads += 1
        guard online else { throw InventoryOffline() }
        if failingFullReads > 0 {
            failingFullReads -= 1
            throw InventoryOffline()
        }
        let listed = inventorySections(items)
        if let gate = fullReadGate {
            fullReadGate = nil
            fullReadEntered?()
            await gate.wait()
        }
        return listed
    }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        filteredReads += 1
        guard online else { throw InventoryOffline() }
        return filter == Self.album ? inventorySections([inventoryItem("a")]) : []
    }
}

private struct InventoryOffline: Error {}

private struct InventoryThumbnails: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        Issue.record("M684_SETUP_THUMBNAILS: disabled thumbnail admission must not load bytes")
        return ThumbnailBatchLoadResult()
    }
}

private enum InventoryEvent: Sendable, Equatable {
    case projectionEntered, ownerFinished, probe, crawlFinished, factsCaptured, fullReadEntered, cacheReadEntered
    case tokenProbeEntered
    case probeCancelled, probeReleased
}

private final class InventoryEvents: Sendable {
    let stream: AsyncStream<InventoryEvent>
    private let continuation: AsyncStream<InventoryEvent>.Continuation
    private let completions = InventoryCounter()
    init() {
        let pair = AsyncStream<InventoryEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }
    var completedCrawls: Int { completions.value }
    func send(_ event: InventoryEvent) {
        if event == .crawlFinished { completions.increment() }
        continuation.yield(event)
    }
    func finish() { continuation.finish() }
}

private final class InventoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if opened { continuation.resume() } else { waiters.append(continuation) }
            }
        }
    }
    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

private final class InventoryProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PhotoUID] = []
    func record(_ uid: PhotoUID) { lock.withLock { recorded.append(uid) } }
    var values: [PhotoUID] { lock.withLock { recorded } }
}

private final class InventorySwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

private final class InventoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
    var value: Int { lock.withLock { count } }
}

private func inventoryUID(_ id: String) -> PhotoUID { PhotoUID(volumeID: "inventory", nodeID: id) }
private func inventoryItem(_ id: String) -> PhotoItem {
    PhotoItem(uid: inventoryUID(id), captureTime: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image/jpeg")
}
private func inventoryCoordinate(_ id: String) -> PhotoCoordinate {
    PhotoCoordinate(
        uid: inventoryUID(id), latitude: 10, longitude: 20, date: Date(timeIntervalSince1970: 1_700_000_000))
}
private func inventorySections(_ items: [PhotoItem]) -> [TimelineSection] {
    items.isEmpty
        ? []
        : [
            TimelineSection(
                id: "inventory", date: items[0].captureTime, title: "Inventory", items: items)
        ]
}
