import CryptoKit
import Foundation
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveSDK
import SQLite3
import Testing
import UploadCore

@testable import PhotosCore
@testable import ProtonDriveBackend

/// The gopenpgp implementation is process-global and injected once (the apps do the same at startup).
private let lineageCryptoReady: Void = {
    injectDefaultCryptoImplementation()
}()

extension DriveSessionStubSuite {
    @Suite struct ProtonRemoteLineageRefreshTests {
        @Test func missingBehindOrFailedLineageUsesTheContentEventPath() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            for mode in ["absent", "missing", "behind", "failed"] {
                StubURLProtocol.reset()
                let lineage: UploadRemoteLineageIndexStore?
                if mode == "absent" {
                    lineage = nil
                } else {
                    lineage = try #require(
                        UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("\(mode).sqlite")))
                }
                defer { lineage?.close() }
                if mode == "behind" || mode == "failed" {
                    #expect(
                        lineage?.replaceRows(
                            identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "older",
                            unresolvedRemoteLinkIDs: []) == true)
                }
                if mode == "failed" {
                    #expect(
                        lineage?.replaceRows(
                            identities: [
                                .init(
                                    hashKeyEpoch: "wrong", remoteLinkID: "bad", externalIdentifier: "cloud",
                                    isMain: true)
                            ],
                            lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []) == false)
                }
                #expect(
                    content.replaceRemoteContentIndex(
                        [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                        unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
                routeEmptyEvents(from: "one", to: "two")
                try await refresh(content: content, lineage: lineage)
                #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "two")
                #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
                #expect(StubURLProtocol.requests().map(\.path) == ["/drive/volumes/vol1/events/one"])
                if let lineage {
                    #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
                }
            }
        }

        /// An account indexed before the lineage index existed has a content checkpoint and no lineage checkpoint.
        /// The index preparation then asks for one full build, which fills both indexes at the same event.
        @Test func aLineageReadRebuildsAMissingOrBehindLineageIndexUnlessItCannotWrite() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for mode in ["missing", "behind", "current", "failed"] {
                let content = try #require(
                    UploadIdentityManifestStore(url: directory.appendingPathComponent("content-\(mode).sqlite")))
                defer { content.close() }
                let lineage = try #require(
                    UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("\(mode).sqlite")))
                defer { lineage.close() }
                if mode != "missing" {
                    #expect(
                        lineage.replaceRows(
                            identities: [], lineage: [], hashKeyEpoch: "epoch",
                            eventID: mode == "current" ? "one" : "older", unresolvedRemoteLinkIDs: []))
                }
                if mode == "failed" {
                    #expect(
                        !lineage.replaceRows(
                            identities: [
                                .init(
                                    hashKeyEpoch: "wrong", remoteLinkID: "bad", externalIdentifier: "cloud",
                                    isMain: true)
                            ],
                            lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
                    #expect(!lineage.acceptsWrites)
                }
                #expect(
                    content.replaceRemoteContentIndex(
                        [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                        unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
                StubURLProtocol.reset()
                routeEmptyEvents(from: "one", to: "two")
                StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
                StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: #"{"Code":1000,"Photos":[]}"#)

                try await refresh(content: content, lineage: lineage, rebuildsMissingLineage: true)

                let paths = StubURLProtocol.requests().map(\.path)
                let contentCheckpoint = content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")
                #expect(contentCheckpoint?.eventID == "two", "\(mode)")
                if mode == "missing" || mode == "behind" {
                    #expect(!paths.contains("/drive/volumes/vol1/events/one"), "\(mode): \(paths)")
                    #expect(paths.contains { $0.hasPrefix("/drive/volumes/vol1/photos") }, "\(mode): \(paths)")
                    #expect(
                        lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: contentCheckpoint) == .complete,
                        "\(mode)")
                } else {
                    #expect(paths == ["/drive/volumes/vol1/events/one"], "\(mode): \(paths)")
                }
            }
        }

        /// After an upgrade, the first resolve of an edited photo reads the missing lineage index as incomplete and
        /// starts no full build, which would hold every duplicate lookup without progress. The index preparation of
        /// the backup and of Duplicates builds it once and reports the progress of that build.
        @Test func aResolveStartsNoLineageRebuildAndTheIndexPreparationRunsItWithProgress() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: #"{"Code":1000,"Photos":[]}"#)
            let service = makeService(content: content, lineage: lineage)

            let read = try await service.activeMainLinkIDs(forExternalIdentifier: "cloud")

            #expect(!read.complete, "an incomplete lineage index proves nothing")
            let resolvePaths = StubURLProtocol.requests().map(\.path)
            #expect(resolvePaths == ["/drive/volumes/vol1/events/one"], "\(resolvePaths)")

            let progress = PreparationLog()
            try await service.prepareRemoteIndex { await progress.append($0) }

            let paths = StubURLProtocol.requests().map(\.path).dropFirst(resolvePaths.count)
            #expect(paths.contains { $0.hasPrefix("/drive/volumes/vol1/photos") }, "\(paths)")
            let phases = await progress.steps.map(\.phase)
            #expect(phases.contains(.indexing), "\(phases)")
            #expect(phases.last == .ready)
            let contentCheckpoint = content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: contentCheckpoint) == .complete)

            let before = StubURLProtocol.requests().count
            try await service.prepareRemoteIndex { _ in }
            let later = StubURLProtocol.requests().dropFirst(before).map(\.path)
            #expect(!later.contains { $0.hasPrefix("/drive/volumes/vol1/photos") }, "the rebuild runs once")
        }

        /// A background window that expires while its pass waits for the index build must end at once. The build
        /// itself keeps running: a later preparation joins it instead of starting a second one, and the timeline
        /// metadata pass stays held until the build ends.
        @Test func aCancelledIndexPreparationStopsWaitingAndTheBuildKeepsRunning() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let laterProgress = LockedOutcome()
            func preparation(reporting reported: LockedOutcome? = nil) -> (Task<Void, Never>, LockedOutcome) {
                let cancelled = LockedOutcome()
                let task = Task {
                    do {
                        try await service.prepareRemoteIndex { _ in reported?.set(true) }
                        cancelled.set(false)
                    } catch {
                        cancelled.set(error is CancellationError)
                    }
                }
                return (task, cancelled)
            }

            let (window, windowCancelled) = preparation()
            try await waitUntil { listings() > 0 }
            #expect(listings() == 1, "the build reached its library listing")
            window.cancel()
            // The listing hangs until the build is invalidated, so the build cannot end before the window does: the
            // window stopped waiting for it instead of waiting until the build ended.
            await windowCancelled.wait()
            #expect(windowCancelled.value == true, "the expired window ended with a cancellation")
            #expect(await service.hasUnfinishedRemoteContentIndexBuild, "the build keeps running after the window")

            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            let (later, laterCancelled) = preparation(reporting: laterProgress)
            // The later preparation reports loading just before it joins the running build.
            await laterProgress.wait()
            try await Task.sleep(for: .milliseconds(300))
            #expect(listings() == 1, "a later preparation joins the running build")
            #expect(released.value == nil, "the metadata pass stays held while the build runs")
            later.cancel()
            await laterCancelled.wait()
            #expect(laterCancelled.value == true, "the joined preparation ended with a cancellation")
            #expect(await service.hasUnfinishedRemoteContentIndexBuild, "the build keeps running after the joiner")
            #expect(released.value == nil, "the joined preparation stopped waiting before the build ended")

            // The end of the build, here through an invalidation, releases the metadata pass.
            await service.invalidateCachedRemoteState()
            await released.wait()
            #expect(released.value == true, "the end of the build releases the metadata pass")
            pass.cancel()
        }

        /// The first launch after the update holds the timeline order pass for the first full index build. A backup
        /// that ends its pass without preparing the index releases it, but only while no build runs or prepares.
        private func gateFixture() throws -> (
            directory: URL, content: UploadIdentityManifestStore, lineage: UploadRemoteLineageIndexStore,
            gate: TimelineMetadataStartGate, released: LockedOutcome, pass: Task<Void, Never>
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            return (directory, content, lineage, gate, released, pass)
        }

        private func waitUntilReleased(_ released: LockedOutcome) async throws {
            await released.wait()
        }

        /// Polls a state that only the stub URL protocol or the gate reports. No time limit decides the result: the
        /// safety net only ends a wait that nothing else ended, and the next expectation of the caller then fails.
        private func waitUntil(_ condition: () async -> Bool) async throws {
            let clock = ContinuousClock()
            let begin = clock.now
            while await !condition(), clock.now - begin < testSafetyNet {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Waits until the timeline pass waits on the gate: a pass that never waits fails here after the safety net.
        private func waitUntilThePassWaits(on gate: TimelineMetadataStartGate) async throws {
            try await waitUntil { gate.waiterCount > 0 || gate.isOpen }
            try #require(gate.waiterCount == 1, "the timeline pass waits on the gate")
        }

        /// Joins `task`: a task that never ends fails here after the safety net and is cancelled instead of hanging the test.
        private func join<T: Sendable>(_ task: Task<T, any Error>, _ comment: Comment) async throws {
            let ended = LockedOutcome()
            let joining = Task {
                _ = await task.result
                ended.set(true)
            }
            try await waitUntilReleased(ended)
            #expect(ended.value == true, comment)
            if ended.value == nil {
                task.cancel()
                joining.cancel()
            }
        }

        @Test func aPassWithoutAnIndexBuildReleasesTheHeldTimelinePass() async throws {
            let fixture = try gateFixture()
            defer {
                fixture.pass.cancel()
                fixture.content.close()
                fixture.lineage.close()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
            StubURLProtocol.reset()
            let service = makeService(content: fixture.content, lineage: fixture.lineage, firstBuildGate: fixture.gate)
            try await waitUntilThePassWaits(on: fixture.gate)
            #expect(fixture.released.value == nil, "the launch that created the lineage index holds the pass")

            await service.remoteIndexPreparationNotNeeded()
            #expect(fixture.gate.isOpen, "no build comes, so the report opens the gate")
            try await waitUntilReleased(fixture.released)
            #expect(fixture.released.value == true, "no build comes, so the pass starts")
        }

        @Test func aRunningBuildKeepsTheTimelinePassHeldAfterAPassWithoutABuild() async throws {
            let fixture = try gateFixture()
            defer {
                fixture.pass.cancel()
                fixture.content.close()
                fixture.lineage.close()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            let service = makeService(content: fixture.content, lineage: fixture.lineage, firstBuildGate: fixture.gate)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let preparation = Task { try await service.prepareRemoteIndex { _ in } }
            try await waitUntil { listings() > 0 }
            #expect(listings() == 1, "the build reached its library listing")
            try await waitUntilThePassWaits(on: fixture.gate)
            // The backup pass stops waiting; the build keeps running.
            preparation.cancel()
            try await join(preparation, "the cancelled preparation returns")

            // The report decides before it returns, so the gate state right after it is the answer.
            await service.remoteIndexPreparationNotNeeded()
            #expect(!fixture.gate.isOpen, "a running build keeps the pass held")
            #expect(fixture.gate.waiterCount == 1)

            await service.invalidateCachedRemoteState()
            try await waitUntilReleased(fixture.released)
            #expect(fixture.released.value == true, "the end of the build releases the pass")
            await service.shutdown()
        }

        /// A build that a duplicate lookup started, without a preparation, keeps the pass held after the report and
        /// releases it when it ends.
        @Test func aReportDuringABuildWithoutAPreparationReleasesThePassWhenThatBuildEnds() async throws {
            let fixture = try gateFixture()
            defer {
                fixture.pass.cancel()
                fixture.content.close()
                fixture.lineage.close()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"one"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/events/one")
            let service = makeService(content: fixture.content, lineage: fixture.lineage, firstBuildGate: fixture.gate)
            func eventReads() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/events/one") }.count
            }
            let lookup = Task {
                try await service.findRemoteAssetProofs(for: [
                    UploadBackupExternalIdentity(identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
                ])
            }
            try await waitUntil { eventReads() > 0 }
            #expect(eventReads() == 1, "the lookup's build reads the changes since its checkpoint")
            try await waitUntilThePassWaits(on: fixture.gate)

            await service.remoteIndexPreparationNotNeeded()
            #expect(!fixture.gate.isOpen, "the build still reads the library")

            await service.invalidateCachedRemoteState()
            try await waitUntilReleased(fixture.released)
            #expect(fixture.released.value == true, "the end of the build releases the pass")
            lookup.cancel()
            try await join(lookup, "the lookup returns")
            await service.shutdown()
        }

        @Test func aPreparationThatHasNotStartedItsBuildKeepsTheTimelinePassHeld() async throws {
            let fixture = try gateFixture()
            defer {
                fixture.pass.cancel()
                fixture.content.close()
                fixture.lineage.close()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            let service = makeService(content: fixture.content, lineage: fixture.lineage, firstBuildGate: fixture.gate)
            let holds = HandlerGate()
            let reached = LockedOutcome()
            let calls = LockedCount()
            // The preparation waits in its first progress report, before it starts the build.
            let preparation = Task {
                try await service.prepareRemoteIndex { _ in
                    if calls.next() == 1 {
                        reached.set(true)
                        await holds.wait()
                    }
                }
            }
            try await waitUntilReleased(reached)
            #expect(reached.value == true, "the preparation waits before its build")
            try await waitUntilThePassWaits(on: fixture.gate)

            await service.remoteIndexPreparationNotNeeded()
            #expect(!fixture.gate.isOpen, "a preparation that is about to build keeps the pass held")
            #expect(fixture.gate.waiterCount == 1)

            preparation.cancel()
            await holds.open()
            try await join(preparation, "the cancelled preparation returns")
            await service.shutdown()
        }

        /// Sign-out closes the account's stores after the shutdown of its work. A build that a cancelled waiter left
        /// running must end first, and no build starts after the shutdown.
        @Test func theShutdownEndsTheRunningBuildAndStartsNoOther() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let window = Task { try await service.prepareRemoteIndex { _ in } }
            try await waitUntil { listings() > 0 }
            #expect(listings() == 1, "the build reached its library listing")
            window.cancel()
            _ = await window.result

            // The hanging listing ends only when the shutdown cancels the build.
            let ended = LockedOutcome()
            let shutdown = Task {
                await service.shutdown()
                // The shutdown returns only after the build ended, so no build can touch the stores after it.
                ended.set(!(await service.hasUnfinishedRemoteContentIndexBuild))
            }
            await ended.wait()
            #expect(ended.value == true, "the shutdown ended the running build")
            shutdown.cancel()
            // The cancelled build ended, so the metadata pass that the cancelled preparation left held is released.
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }
            await released.wait()
            #expect(released.value == true, "the shutdown cancelled the build")

            let requestsBefore = StubURLProtocol.requests().count
            let afterShutdown = LockedOutcome()
            let late = Task {
                do {
                    try await service.prepareRemoteIndex { _ in }
                    afterShutdown.set(false)
                } catch {
                    afterShutdown.set(error is CancellationError)
                }
            }
            await afterShutdown.wait()
            late.cancel()
            #expect(afterShutdown.value == true, "a preparation after the shutdown ends with a cancellation")
            #expect(StubURLProtocol.requests().count == requestsBefore, "no build starts after the shutdown")
        }

        /// An invalidation cancels a build without waiting for it. The shutdown still waits for that build, so it cannot
        /// touch the stores after the shutdown.
        @Test func theShutdownWaitsForABuildThatAnInvalidationCancelled() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            let service = makeService(content: content, lineage: lineage)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let pass = Task { try await service.prepareRemoteIndex { _ in } }
            try await waitUntil { listings() > 0 }
            #expect(listings() == 1, "the build reached its library listing")

            await service.invalidateCachedRemoteState()
            await service.shutdown()

            #expect(
                !(await service.hasUnfinishedRemoteContentIndexBuild),
                "the cancelled build ended before the shutdown returned")
            _ = await pass.result
        }

        /// A preparation that needs the first full build can stop while a shorter refresh runs. The end of that refresh
        /// is not the end of the first full build, so the timeline metadata pass stays held.
        @Test func theEndOfAShorterRefreshKeepsThePassHeldForTheFirstFullBuild() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            StubURLProtocol.hang("GET /drive/volumes/vol1/events/one")
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func eventReads() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/events/one") }.count
            }
            // An asset proof starts the shorter refresh of the events, which hangs.
            let proof = Task {
                try await service.findRemoteAssetProofs(for: [
                    UploadBackupExternalIdentity(identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
                ])
            }
            try await waitUntil { eventReads() > 0 }
            #expect(eventReads() == 1, "the shorter refresh reads the events")
            // The preparation needs the lineage rebuild, waits for the running refresh and then stops.
            let loading = LockedOutcome()
            let preparation = Task { try await service.prepareRemoteIndex { _ in loading.set(true) } }
            await loading.wait()
            try await Task.sleep(for: .milliseconds(300))
            preparation.cancel()
            _ = await preparation.result
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }

            // The refresh ends without the lineage rebuild.
            await service.invalidateCachedRemoteState()
            _ = await proof.result
            try await Task.sleep(for: .milliseconds(300))

            #expect(released.value == nil, "the pass stays held for the first full build")
        }

        /// Series dissolution and the edit replacement hold the service directly, so they can reach it after the shutdown.
        /// The identity stores may be closed by then, so neither method writes any more.
        @Test func aServiceThatIsShutDownInvalidatesNothingAndRecordsNothing() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            var hasher = SHA256()
            hasher.update(data: Data("a".utf8))
            hasher.update(data: Data([0]))
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let service = makeService(content: content, lineage: nil)
            await service.recordUploaded(contentHash: "early", remoteLinkID: "link-early")
            #expect(
                content.remoteContentRecord(contentHash: "early", hashKeyEpoch: "epoch") != nil, "before the shutdown")
            // A new record ends a staged build, so the build starts after it.
            #expect(
                content.beginRemoteContentIndexBuild(
                    hashKeyEpoch: "epoch", eventID: "e1", sourceFingerprint: fingerprint, total: 1, updatedAt: Date())
                    != nil)
            #expect(content.remoteContentIndexBuildCheckpoint(hashKeyEpoch: "epoch") != nil, "the staged build exists")

            await service.shutdown()
            await service.invalidateCachedRemoteState()
            await service.recordUploaded(contentHash: "late", remoteLinkID: "link-late")

            #expect(
                content.remoteContentIndexBuildCheckpoint(hashKeyEpoch: "epoch") != nil,
                "the invalidation after the shutdown leaves the staged build alone")
            #expect(
                content.remoteContentRecord(contentHash: "late", hashKeyEpoch: "epoch") == nil,
                "no write after the shutdown")
        }

        /// Sequence B: a lineage rebuild L, whose preparation was cancelled, is cancelled by an invalidation, and another
        /// caller starts a build N before L ends. L's end must neither release the metadata pass nor clear N.
        private func sequenceB(
            _ body: (_ service: ProtonUploadDedupeService, _ gate: TimelineMetadataStartGate, _ released: LockedOutcome)
                async throws -> Void
        ) async throws {
            try await invalidatedLineageRebuild { service, gate, released, holdsTheBuild in
                let requestsBeforeN = StubURLProtocol.requests().count
                let newer = Task {
                    try await service.findRemoteAssetProofs(for: [
                        UploadBackupExternalIdentity(
                            identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
                    ])
                }
                try await waitUntil { StubURLProtocol.requests().count != requestsBeforeN }
                #expect(await service.unfinishedRemoteContentIndexBuildCount == 2, "L and N run")

                await holdsTheBuild.open()
                try await waitUntil { await service.unfinishedRemoteContentIndexBuildCount <= 1 }
                #expect(await service.unfinishedRemoteContentIndexBuildCount == 1, "L ended and N still runs")
                try await body(service, gate, released)
                await service.shutdown()
                newer.cancel()
                _ = await newer.result
            }
        }

        /// A lineage rebuild L, whose preparation was cancelled, is cancelled by an invalidation. L still waits in the
        /// handler of that preparation, so it has not ended; `holdsTheBuild` lets it end.
        private func invalidatedLineageRebuild(
            _ body: (
                _ service: ProtonUploadDedupeService, _ gate: TimelineMetadataStartGate, _ released: LockedOutcome,
                _ holdsTheBuild: HandlerGate
            ) async throws -> Void
        ) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"one"}"#)
            StubURLProtocol.hang("GET /drive/volumes/vol1/photos")
            StubURLProtocol.hang("GET /drive/volumes/vol1/events/one")
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }
            let holdsTheBuild = HandlerGate()
            let reachedTheBuild = LockedOutcome()

            // The preparation's handler holds the lineage rebuild L at its first progress, before L asks for anything.
            let calls = LockedCount()
            let preparation = Task {
                try await service.prepareRemoteIndex { _ in
                    if calls.next() == 2 {
                        reachedTheBuild.set(true)
                        await holdsTheBuild.wait()
                    }
                }
            }
            await reachedTheBuild.wait()
            #expect(reachedTheBuild.value == true, "L runs and waits in the handler")
            preparation.cancel()
            _ = await preparation.result
            await service.invalidateCachedRemoteState()
            try await body(service, gate, released, holdsTheBuild)
            await holdsTheBuild.open()
            await service.shutdown()
        }

        @Test func aReportWhileAnInvalidatedBuildStillRunsKeepsThePassHeldUntilThatBuildEnds() async throws {
            try await invalidatedLineageRebuild { service, gate, released, holdsTheBuild in
                #expect(await service.unfinishedRemoteContentIndexBuildCount == 1, "the invalidated build L still runs")
                await service.remoteIndexPreparationNotNeeded()
                #expect(!gate.isOpen, "a build that started before the report still reads the library")

                await holdsTheBuild.open()
                try await waitUntilReleased(released)
                #expect(released.value == true, "the end of that build releases the pass")
            }
        }

        @Test func theEndOfAnOlderLineageRebuildKeepsThePassHeldWhileANewerBuildRuns() async throws {
            try await sequenceB { _, _, released in
                try await Task.sleep(for: .milliseconds(300))
                #expect(released.value == nil, "L ended with the lineage rebuilt, but N still runs")
            }
        }

        @Test func theEndOfAnOlderBuildDoesNotClearTheNewerBuild() async throws {
            try await sequenceB { service, _, _ in
                let requests = StubURLProtocol.requests().count
                // A later caller finds N still running and joins it, instead of starting a build of its own.
                let later = Task {
                    try await service.findRemoteAssetProofs(for: [
                        UploadBackupExternalIdentity(
                            identifier: "other", modificationDate: Date(timeIntervalSince1970: 0))
                    ])
                }
                try await Task.sleep(for: .milliseconds(300))
                #expect(StubURLProtocol.requests().count == requests, "no second build started beside N")
                later.cancel()
                _ = await later.result
            }
        }

        /// A build that ended no longer counts as running: once its result is no longer current, the next preparation
        /// refreshes the index again instead of reusing the ended build.
        @Test func anEndedBuildLetsTheNextPreparationRefreshAgain() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            routeEmptyEvents(from: "two", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: #"{"Code":1000,"Photos":[]}"#)
            let service = makeService(content: content, lineage: lineage)
            func eventReads() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/events") }.count
            }

            try await service.prepareRemoteIndex { _ in }
            let afterFirst = eventReads()
            #expect(afterFirst > 0, "the first preparation reads the events")
            // A trash of main photos on this device makes the refreshed index no longer current.
            await service.remoteMainsChangedHere()
            try await service.prepareRemoteIndex { _ in }

            #expect(eventReads() > afterFirst, "the next preparation refreshes again")
        }

        /// A merge trashes main photos while the library check runs. The trash is a later event than the build, so the
        /// staged build stays and resumes where it stopped; a full invalidation still discards it.
        @Test func aTrashOfMainPhotosKeepsTheStagedBuildAndTheBuildResumes() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            var hasher = SHA256()
            for id in ["a", "b"] {
                hasher.update(data: Data(id.utf8))
                hasher.update(data: Data([0]))
            }
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let build = try #require(
                content.beginRemoteContentIndexBuild(
                    hashKeyEpoch: "epoch", eventID: "e1", sourceFingerprint: fingerprint, total: 2, updatedAt: Date()))
            #expect(
                content.appendRemoteContentIndexBuild(
                    records: ["a", "b"].map { .init(contentHash: "same", hashKeyEpoch: "epoch", remoteLinkID: $0) },
                    unresolvedIssues: [], externalIdentities: [], hashKeyEpoch: "epoch", buildID: build.buildID,
                    nextCursor: 2, updatedAt: Date()))
            let service = makeService(content: content, lineage: nil)

            await service.remoteMainsChangedHere()

            #expect(content.remoteContentIndexBuildCheckpoint(hashKeyEpoch: "epoch")?.cursor == 2)
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"e1"}"#)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/photos",
                json: #"{"Code":1000,"Photos":[{"LinkID":"a","CaptureTime":1,"Tags":[],"RelatedPhotos":[]},"#
                    + #"{"LinkID":"b","CaptureTime":2,"Tags":[],"RelatedPhotos":[]}]}"#)
            try await service.prepareRemoteIndex { _ in }
            let paths = StubURLProtocol.requests().map(\.path)
            #expect(!paths.contains { $0.contains("fetch_metadata") }, "the build resumes after its rows: \(paths)")
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "e1")
            #expect(content.remoteContentDuplicateGroups(hashKeyEpoch: "epoch") == ["same": ["a", "b"]])

            let second = try #require(
                content.beginRemoteContentIndexBuild(
                    hashKeyEpoch: "epoch", eventID: "e2", sourceFingerprint: fingerprint, total: 2, updatedAt: Date()))
            #expect(second.cursor == 0)
            await service.invalidateCachedRemoteState()
            #expect(content.remoteContentIndexBuildCheckpoint(hashKeyEpoch: "epoch") == nil)
        }

        @Test func lineageWriteFailureDisablesFurtherWritesWhileContentKeepsRefreshing() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let url = directory.appendingPathComponent("lineage.sqlite")
            let lineage = try #require(UploadRemoteLineageIndexStore(url: url))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            var db: OpaquePointer?
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(
                sqlite3_exec(
                    db,
                    """
                    CREATE TRIGGER reject_checkpoint BEFORE INSERT ON lineage_checkpoint
                    BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
                    """, nil, nil, nil) == SQLITE_OK)
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "two")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .incomplete)
            #expect(sqlite3_exec(db, "DROP TRIGGER reject_checkpoint;", nil, nil, nil) == SQLITE_OK)
            #expect(
                !lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "two", unresolvedRemoteLinkIDs: []))
            routeEmptyEvents(from: "two", to: "three")
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "three")
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
            #expect(
                StubURLProtocol.requests().map(\.path) == [
                    "/drive/volumes/vol1/events/one", "/drive/volumes/vol1/events/two",
                ])
        }

        @Test func missingLineageStagingDoesNotRestartAResumedContentBuild() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            let fingerprint = SHA256.hash(data: Data("main\0".utf8)).map { String(format: "%02x", $0) }.joined()
            let build = try #require(
                content.beginRemoteContentIndexBuild(
                    hashKeyEpoch: "epoch", eventID: "one", sourceFingerprint: fingerprint, total: 1, updatedAt: Date()))
            #expect(
                content.appendRemoteContentIndexBuild(
                    records: [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], externalIdentities: [], hashKeyEpoch: "epoch", buildID: build.buildID,
                    nextCursor: 1, updatedAt: Date()))
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"one"}"#)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/photos",
                json: #"{"Code":1000,"Photos":[{"LinkID":"main","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#)
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .incomplete)
            #expect(StubURLProtocol.requests().map(\.path).filter { $0.contains("fetch_metadata") }.isEmpty)
            #expect(StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count == 2)
        }

        @Test func unresolvedMetadataSurvivesEmptyEventsUntilTheLinksAreRemoved() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json: #"""
                    {"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"missing","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"state","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"photo","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"unknown","Type":2,"State":99}}
                    ]}
                    """#)
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata",
                json: #"""
                    {"Code":1000,"Links":[
                        {"LinkID":"state","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{}}}},
                        {"LinkID":"photo","Type":2,"State":1}
                    ]}
                    """#)
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "two"))
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch").isEmpty)
            routeEmptyEvents(from: "two", to: "three")
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/three",
                json: #"""
                    {"Code":1000,"EventID":"four","More":0,"Refresh":0,"Events":[
                        {"EventType":0,"Link":{"LinkID":"missing"}},
                        {"EventType":0,"Link":{"LinkID":"state"}},
                        {"EventType":0,"Link":{"LinkID":"photo"}},
                        {"EventType":0,"Link":{"LinkID":"unknown"}}
                    ]}
                    """#)
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("four")) == .complete)
            #expect(!StubURLProtocol.requests().contains { $0.path.contains("/photos") })
        }

        /// One failed metadata read during a build left a link unresolved. The next event apply reads it again, so the
        /// index becomes complete without a full build.
        @Test func aRepairCompletesTheIndexAfterOneFailedRead() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            let keys = try LineageKeys()
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                    unresolvedRemoteLinkIDs: ["photo", "trashed"]))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            try routeMetadata([
                try keys.activePhoto(
                    "photo",
                    attributes: #"{"iOS.photos":{"ICloudID":"cloud"},"#
                        + #""EncryptedMemories.lineage":{"V":1,"Reason":"edit","Replaces":["old"]}}"#),
                ["LinkID": "trashed", "Type": 2, "State": 2],
            ])

            try await refresh(content: content, lineage: lineage, rootKey: keys.root)

            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .complete)
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch") == ["photo"])
            #expect(lineage.replacingMainLinkIDs(ofReplacedLink: "old", hashKeyEpoch: "epoch") == ["photo"])
            #expect(try metadataRequestLinkIDs().sorted() == ["photo", "trashed"])
        }

        /// A link that fails again stays unresolved, and a later sweep reads it again.
        @Test func aLinkThatFailsAgainStaysAndALaterSweepRetriesIt() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let url = directory.appendingPathComponent("lineage.sqlite")
            let keys = try LineageKeys()
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            do {
                let lineage = try #require(UploadRemoteLineageIndexStore(url: url))
                defer { lineage.close() }
                #expect(
                    lineage.replaceRows(
                        identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                        unresolvedRemoteLinkIDs: ["photo", "unreadable"]))
                StubURLProtocol.reset()
                routeEmptyEvents(from: "one", to: "two")
                StubURLProtocol.route(
                    "POST /drive/shares/share1/links/fetch_metadata", status: 422,
                    json: #"{"Code":2000,"Error":"failed"}"#)
                try await refresh(content: content, lineage: lineage, rootKey: keys.root)
                #expect(lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "two"))
                #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
                #expect(Set(try metadataRequestLinkIDs()) == ["photo", "unreadable"])
            }
            // The next launch starts a new sweep. The readable link resolves; the unreadable one stays.
            let lineage = try #require(UploadRemoteLineageIndexStore(url: url))
            defer { lineage.close() }
            StubURLProtocol.reset()
            routeEmptyEvents(from: "two", to: "three")
            try routeMetadata([
                try keys.activePhoto("photo", attributes: #"{"iOS.photos":{"ICloudID":"cloud"}}"#),
                [
                    "LinkID": "unreadable", "Type": 2, "State": 1, "NodeKey": "broken", "NodePassphrase": "broken",
                    "XAttr": "broken", "FileProperties": ["ActiveRevision": ["Photo": [:] as [String: Any]]],
                ],
            ])
            try await refresh(content: content, lineage: lineage, rootKey: keys.root)
            #expect(Set(try metadataRequestLinkIDs()) == ["photo", "unreadable"])
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch") == ["photo"])
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
            let reopened = try #require(UploadRemoteLineageIndexStore(url: url))
            defer { reopened.close() }
            #expect(
                reopened.unresolvedLinkIDsForRepair(hashKeyEpoch: "epoch", limit: 10, sweepInterval: 0)
                    == ["unreadable"])
        }

        /// Proton sends state 3 for a link that is deleted for good. Such a link leaves the index, from an event and
        /// from a repair read. State 4 (restoring) and unknown states stay unresolved.
        @Test func aDeletedLinkStateDoesNotBlockTheIndex() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [
                        .init(hashKeyEpoch: "epoch", remoteLinkID: "event", externalIdentifier: "cloud", isMain: true)
                    ],
                    lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: ["read"]))
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json: #"""
                    {"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"event","Type":2,"State":3}}
                    ]}
                    """#)
            try routeMetadata([["LinkID": "read", "Type": 2, "State": 3]])
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .complete)
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch").isEmpty)

            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/two",
                json: #"""
                    {"Code":1000,"EventID":"three","More":0,"Refresh":0,"Events":[
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"restoring","Type":2,"State":4}}
                    ]}
                    """#)
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
        }

        /// A large backlog never stalls a pass: one repair reads one metadata window, the next pass continues the
        /// sweep, and a finished sweep waits for its interval.
        @Test func oneRepairReadsABoundedShareOfTheBacklog() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            let backlog = (0..<601).map { String(format: "link%04d", $0) }
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                    unresolvedRemoteLinkIDs: Set(backlog)))
            StubURLProtocol.reset()
            try routeMetadata([])
            routeEmptyEvents(from: "one", to: "two")

            try await refresh(content: content, lineage: lineage)
            #expect(Set(try metadataRequestLinkIDs()) == Set(backlog.prefix(600)))
            #expect(StubURLProtocol.requests().filter { $0.path.contains("fetch_metadata") }.count <= 8)

            StubURLProtocol.reset()
            try routeMetadata([])
            routeEmptyEvents(from: "two", to: "three")
            try await refresh(content: content, lineage: lineage)
            #expect(try metadataRequestLinkIDs() == ["link0600", "link0600"])

            StubURLProtocol.reset()
            routeEmptyEvents(from: "three", to: "four")
            try await refresh(content: content, lineage: lineage)
            #expect(try metadataRequestLinkIDs().isEmpty)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("four")) == .incomplete)
        }

        /// Proton leaves a link that is deleted for good out of the metadata response. Two repair reads one sweep
        /// interval apart that both leave it out settle it, and the index can become complete.
        @Test func aLinkLeftOutOfTwoRepairReadsLeavesTheIndex() async throws {
            let fixture = try RepairFixture(unresolved: ["gone"])
            defer { fixture.close() }
            try routeMetadata([])
            try await fixture.refresh(to: "two")
            #expect(fixture.lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)

            fixture.clock.advance(ProtonUploadDedupeService.lineageRepairSweepInterval)
            try await fixture.refresh(to: "three")
            #expect(try metadataRequestLinkIDs().filter { $0 == "gone" }.count == 4, "two reads with one retry each")
            #expect(fixture.lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .complete)
        }

        @Test func aLinkLeftOutOnceAndThenReturnedGetsItsRows() async throws {
            let fixture = try RepairFixture(unresolved: ["photo"])
            defer { fixture.close() }
            try routeMetadata([])
            try await fixture.refresh(to: "two")
            fixture.clock.advance(ProtonUploadDedupeService.lineageRepairSweepInterval)
            try routeMetadata([
                try fixture.keys.activePhoto("photo", attributes: #"{"iOS.photos":{"ICloudID":"cloud"}}"#)
            ])
            try await fixture.refresh(to: "three")
            #expect(
                fixture.lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch") == ["photo"])
            #expect(fixture.lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .complete)
        }

        /// A failed request proves nothing about a link: it neither counts as an omission nor settles one.
        @Test func aFailedRequestNeverSettlesALink() async throws {
            let fixture = try RepairFixture(unresolved: ["photo"])
            defer { fixture.close() }
            try routeMetadata([])
            try await fixture.refresh(to: "two")
            for next in ["three", "four"] {
                fixture.clock.advance(ProtonUploadDedupeService.lineageRepairSweepInterval)
                StubURLProtocol.route(
                    "POST /drive/shares/share1/links/fetch_metadata", status: 422,
                    json: #"{"Code":2000,"Error":"failed"}"#)
                try await fixture.refresh(to: next)
                #expect(
                    fixture.lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint(next)) == .incomplete)
            }
            #expect(try metadataRequestLinkIDs().filter { $0 == "photo" }.count == 6)
        }

        /// The repair runs after the events, so a hanging or failing repair read never holds them back.
        @Test func eventsApplyWhileTheRepairReadHangs() async throws {
            let fixture = try RepairFixture(unresolved: ["photo"])
            defer { fixture.close() }
            StubURLProtocol.hang("POST /drive/shares/share1/links/fetch_metadata")
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json: #"""
                    {"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[
                        {"EventType":0,"Link":{"LinkID":"removed"}}
                    ]}
                    """#)
            let refresh = Task { try await fixture.refresh(to: "two", routesEvents: false) }
            for _ in 0..<500 {
                if StubURLProtocol.requests().contains(where: { $0.path.contains("fetch_metadata") }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(StubURLProtocol.requests().contains { $0.path.contains("fetch_metadata") })
            #expect(fixture.content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "two")
            #expect(fixture.lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "two"))
            refresh.cancel()
            _ = await refresh.result
            #expect(fixture.lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
        }

        @Test func contentPageFailureKeepsBothCheckpointsAndRows() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let contentURL = directory.appendingPathComponent("content.sqlite")
            let content = try #require(UploadIdentityManifestStore(url: contentURL))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [
                        .init(hashKeyEpoch: "epoch", remoteLinkID: "main", externalIdentifier: "cloud", isMain: true)
                    ],
                    lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            var db: OpaquePointer?
            #expect(sqlite3_open(contentURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(
                sqlite3_exec(
                    db,
                    """
                    CREATE TRIGGER reject_content_checkpoint BEFORE INSERT ON remote_content_index_checkpoint
                    BEGIN SELECT RAISE(ABORT, 'test page failure'); END;
                    """, nil, nil, nil) == SQLITE_OK)
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json:
                    #"{"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[{"EventType":0,"Link":{"LinkID":"main"}}]}"#
            )
            await #expect(throws: UploadError.self) {
                try await refresh(content: content, lineage: lineage)
            }
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "one")
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch") == ["main"])
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .complete)
        }

        @Test func relatedPhotosOfAMainPhotoNeedTheirList() throws {
            func metadata(_ photo: String) throws -> [AlbumPhotoMetadata] {
                let json = #"{"Link":{"LinkID":"main"},"Photo":"# + photo + "}"
                return [try JSONDecoder().decode(AlbumPhotoMetadata.self, from: Data(json.utf8))]
            }

            #expect(
                try ProtonUploadDedupeService.relatedPhotoLinkIDs(
                    ofMainLinkID: "main", in: metadata(#"{"RelatedPhotosLinkIDs":["frame"]}"#)) == ["frame"])
            #expect(
                try ProtonUploadDedupeService.relatedPhotoLinkIDs(
                    ofMainLinkID: "main", in: metadata(#"{"RelatedPhotosLinkIDs":[]}"#)
                ).isEmpty)
            // A response without the list is incomplete. Read as "no related photos", it uploads a frame again.
            #expect(throws: UploadError.self) {
                try ProtonUploadDedupeService.relatedPhotoLinkIDs(
                    ofMainLinkID: "main", in: metadata(#"{"CaptureTime":1}"#))
            }
            #expect(throws: UploadError.self) {
                try ProtonUploadDedupeService.relatedPhotoLinkIDs(ofMainLinkID: "main", in: [])
            }
        }

        /// At the first launch after the update the lineage index has no checkpoint, so the index preparation runs the
        /// first full build. The timeline metadata pass reads the whole library too; it starts after the build ends.
        @Test func theFirstFullBuildHoldsTheTimelineMetadataPassUntilItEnds() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            StubURLProtocol.route("GET /drive/volumes/vol1/photos", json: #"{"Code":1000,"Photos":[]}"#)
            // The build outlasts the start limit, which applies only until a build starts. The test ends the start-limit
            // wait of the gate while the build runs; the limit that follows never ends on its own.
            let startLimit = StartLimitHold(then: Self.neverFires)
            let gate = TimelineMetadataStartGate(startLimit: .seconds(1), limit: .seconds(60), sleep: startLimit.sleep)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let reconciliation = TimelineMetadataReconciliation(startGate: gate)
            let events = BuildOrderLog()
            reconciliation.schedule(timelineInventory) { _ in await events.append("metadata pass") }

            try await service.prepareRemoteIndex { step in
                // The last progress comes a moment after the build ends; the pass still starts only after it.
                if step.phase == .ready { try? await Task.sleep(for: .milliseconds(500)) }
                await events.append("build \(step.phase)")
                if step.phase == .indexing {
                    startLimit.end()
                    try? await Task.sleep(for: .milliseconds(1_500))
                }
            }
            #expect(await passStart(events, reconciliation))

            let log = await events.entries
            #expect(log.contains("build indexing"), "\(log)")
            #expect(Array(log.suffix(2)) == ["build ready", "metadata pass"], "\(log)")
        }

        /// A refresh for an asset proof is no first full build. It ends while no preparation waits, and the pass stays held
        /// for the preparation that builds the index.
        @Test func aRefreshForAnAssetProofKeepsTheTimelineMetadataPassHeld() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }

            _ = try await service.findRemoteAssetProofs(for: [
                UploadBackupExternalIdentity(identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
            ])
            #expect(
                StubURLProtocol.requests().contains { $0.path.hasPrefix("/drive/volumes/vol1/events") },
                "the proof lookup refreshed the index")
            try await Task.sleep(for: .milliseconds(300))
            #expect(released.value == nil, "the pass stays held for the first full build")

            // A pass that is already cancelled starts no refresh, also when the index is no longer current.
            await service.remoteMainsChangedHere()
            let requestsBefore = StubURLProtocol.requests().count
            let cancelledPass = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.prepareRemoteIndex { _ in }
            }
            await #expect(throws: CancellationError.self) { try await cancelledPass.value }
            try await Task.sleep(for: .milliseconds(300))
            #expect(StubURLProtocol.requests().count == requestsBefore, "the cancelled pass started no refresh")
        }

        @Test func aFailedFirstBuildReleasesTheTimelineMetadataPass() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            StubURLProtocol.reset()
            let gate = TimelineMetadataStartGate(
                startLimit: .seconds(20), limit: .seconds(20), sleep: Self.neverFires)
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let reconciliation = TimelineMetadataReconciliation(startGate: gate)
            let events = BuildOrderLog()
            reconciliation.schedule(timelineInventory) { _ in await events.append("metadata pass") }

            await #expect(throws: (any Error).self) {
                try await service.prepareRemoteIndex { step in
                    await events.append("build \(step.phase)")
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }

            #expect(await passStart(events, reconciliation), "the failed build must release the pass")
            let log = await events.entries
            #expect(log.first == "build loading", "\(log)")
            #expect(log.last == "metadata pass", "the pass waits for the failure: \(log)")
        }

        /// Only the launch that created the lineage index holds the pass. A later launch, also one whose earlier build
        /// never ran, and a launch without a writable lineage index start the pass as before.
        @Test func aLaterLaunchStartsTheTimelineMetadataPassAtOnce() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            for mode in ["absent", "without checkpoint", "with checkpoint", "closed"] {
                let url = directory.appendingPathComponent("\(mode).sqlite")
                var lineage: UploadRemoteLineageIndexStore?
                if mode != "absent" {
                    let earlier = try #require(UploadRemoteLineageIndexStore(url: url))
                    #expect(earlier.createdFile, "\(mode)")
                    if mode == "with checkpoint" {
                        #expect(
                            earlier.replaceRows(
                                identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                                unresolvedRemoteLinkIDs: []))
                    }
                    if mode == "closed" {
                        earlier.close()
                        lineage = earlier
                    } else {
                        earlier.close()
                        lineage = try #require(UploadRemoteLineageIndexStore(url: url))
                        #expect(lineage?.createdFile == false, "\(mode)")
                    }
                }
                defer { lineage?.close() }
                let events = BuildOrderLog()
                // A later launch opens the gate at once. A pass that reaches the gate wait anyway is held, and the wait
                // starts the sleeper of the gate, so the sleeper ends the wait for the start instead of any time limit.
                let gate = TimelineMetadataStartGate(
                    startLimit: .seconds(20), limit: .seconds(20),
                    sleep: { duration in
                        await events.giveUp()
                        try await Self.neverFires(duration)
                    })
                _ = makeService(content: content, lineage: lineage, firstBuildGate: gate)
                let reconciliation = TimelineMetadataReconciliation(startGate: gate)

                reconciliation.schedule(timelineInventory) { _ in await events.append("metadata pass") }

                #expect(await passStart(events, reconciliation), "\(mode): a later launch must not hold the pass")
                gate.open()
            }
        }

        /// Waits until the pass logs its start, then retires the scheduler so a held pass cannot outlive the test.
        /// No time limit decides the result: the wait ends when the pass starts, or when the log gives up. The safety
        /// net gives up only after a wait that nothing else ended, so a hung pass fails the test and cannot hang it.
        private func passStart(
            _ events: BuildOrderLog, _ reconciliation: TimelineMetadataReconciliation
        ) async -> Bool {
            let safetyNet = Task {
                do { try await Task.sleep(for: testSafetyNet) } catch { return }
                await events.giveUp()
            }
            let started = await events.waitFor("metadata pass")
            safetyNet.cancel()
            reconciliation.retire()
            await reconciliation.waitForCurrentPass()
            return started
        }

        /// A gate sleeper that ends only when its task is cancelled, which `open()` does to the timer of the gate. A
        /// gate with this sleeper releases a waiting pass only through `open()`, never through its time limits. With a
        /// real limit, a pass that production code wrongly holds would start when the limit ends and pass the test.
        private static func neverFires(_ duration: Duration) async throws {
            try await Task.sleep(for: .seconds(24 * 60 * 60))
        }

        private var timelineInventory: TimelineMetadataReconciliation.Inventory {
            .init(
                items: [
                    PhotoItem(
                        uid: PhotoUID(volumeID: "vol1", nodeID: "photo"), captureTime: Date(timeIntervalSince1970: 1),
                        mediaType: "image/jpeg")
                ], classifiedNodeIDs: [], libraryID: "vol1")
        }

        @Test(arguments: ["initial", "retry", "repair", "lineage"])
        func requestCancellationNeverSettlesADegradedIndex(route: String) async throws {
            let fixture = try RepairFixture(unresolved: route == "lineage" ? ["photo"] : [])
            defer { fixture.close() }
            let metadataPath = "POST /drive/shares/share1/links/fetch_metadata"
            if route == "lineage" {
                StubURLProtocol.fail(metadataPath)
                await #expect(throws: (any Error).self) { try await fixture.refresh(to: "two") }
                #expect(try metadataRequestLinkIDs() == ["photo"], "no retry after cancellation")
                fixture.clock.advance(10_000)
                #expect(
                    fixture.lineage.unresolvedLinkIDsForRepair(
                        hashKeyEpoch: "epoch", limit: 10, sweepInterval: 0
                    ).contains("photo"))
            } else {
                StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"two"}"#)
                StubURLProtocol.route(
                    "GET /drive/volumes/vol1/photos",
                    json: #"{"Code":1000,"Photos":[{"LinkID":"photo","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#)
                if route == "repair" {
                    var photo = try fixture.keys.activePhoto("photo", attributes: "{}")
                    photo["Name"] = try fixture.keys.crypto.encrypt(text: "photo.heic", to: fixture.keys.root)
                    try routeMetadata([photo])
                    StubURLProtocol.fail("POST /drive/volumes/vol1/photos/duplicates")
                } else {
                    try routeMetadata([])
                    StubURLProtocol.fail(metadataPath, afterResponses: route == "retry" ? 1 : 0)
                }
                let fresh = try #require(
                    UploadIdentityManifestStore(
                        url: fixture.directory.appendingPathComponent("fresh.sqlite")))
                defer { fresh.close() }
                do {
                    try await ProtonUploadDedupeService.refreshRemoteContentIndex(
                        material: Self.material(rootKey: fixture.keys.root), session: makeSession(),
                        crypto: fixture.keys.crypto, store: fresh, lineageStore: nil,
                        rebuildsMissingLineage: false, progress: { _ in })
                    Issue.record("request cancellation must propagate from \(route)")
                } catch { #expect(UploadError.isCancellation(error)) }
                #expect(fresh.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch") == nil)
                if route != "repair" {
                    #expect(try metadataRequestLinkIDs().count == (route == "retry" ? 2 : 1))
                } else {
                    #expect(StubURLProtocol.requests().contains { $0.path.contains("/photos/duplicates") })
                }
            }
            #expect(!Task.isCancelled)
        }

        private func makeService(
            content: UploadIdentityManifestStore, lineage: UploadRemoteLineageIndexStore?,
            firstBuildGate: TimelineMetadataStartGate? = nil
        ) -> ProtonUploadDedupeService {
            ProtonUploadDedupeService(
                session: makeSession(), crypto: DriveCrypto(addressKeys: [], signers: []),
                photosClient: NoPhotoDuplicates(), contentIndexStore: content, lineageIndexStore: lineage,
                material: material, firstBuildGate: firstBuildGate
            ) { throw UploadError.backend("The test material is resolved") }
        }

        private var material: ProtonUploadDedupeService.Material {
            Self.material(rootKey: .init(armored: "", passphrase: ""))
        }

        private static func material(rootKey: UnlockableKey) -> ProtonUploadDedupeService.Material {
            .init(
                context: .init(volumeID: "vol1", shareID: "share1", rootLinkID: "root1"),
                rootKey: rootKey, hashKey: Data(), epoch: "epoch")
        }

        private func makeSession() -> DriveSession { Self.makeSession() }

        private static func makeSession() -> DriveSession {
            DriveSession(
                session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: FileManager.default.temporaryDirectory,
                urlProtocolClasses: [StubURLProtocol.self])
        }

        private func checkpoint(_ eventID: String) -> UploadRemoteContentIndexCheckpoint {
            .init(eventID: eventID, refreshedAt: Date())
        }

        private func routeEmptyEvents(from: String, to: String) {
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/\(from)",
                json: #"{"Code":1000,"EventID":"\#(to)","More":0,"Refresh":0,"Events":[]}"#)
        }

        private final class ManualClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_000_000)
            var now: Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
        }

        /// A content and a lineage index at event "one" with unresolved lineage links, and a clock for the sweeps.
        private struct RepairFixture: Sendable {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let clock = ManualClock()
            let keys: LineageKeys
            let content: UploadIdentityManifestStore
            let lineage: UploadRemoteLineageIndexStore

            init(unresolved: Set<String>) throws {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                keys = try LineageKeys()
                content = try #require(
                    UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
                let clock = clock
                lineage = try #require(
                    UploadRemoteLineageIndexStore(
                        url: directory.appendingPathComponent("lineage.sqlite"), clock: { clock.now }))
                #expect(
                    content.replaceRemoteContentIndex(
                        [], unresolvedIssues: [], hashKeyEpoch: "epoch",
                        checkpoint: .init(eventID: "one", refreshedAt: Date())))
                #expect(
                    lineage.replaceRows(
                        identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                        unresolvedRemoteLinkIDs: unresolved))
                StubURLProtocol.reset()
            }

            /// Applies empty events from the current checkpoint to `next`, with the repair after them.
            func refresh(to next: String, routesEvents: Bool = true) async throws {
                let current = content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID ?? ""
                if routesEvents {
                    StubURLProtocol.route(
                        "GET /drive/volumes/vol1/events/\(current)",
                        json: #"{"Code":1000,"EventID":"\#(next)","More":0,"Refresh":0,"Events":[]}"#)
                }
                try await ProtonRemoteLineageRefreshTests.refresh(
                    content: content, lineage: lineage, rootKey: keys.root)
            }

            func close() {
                content.close()
                lineage.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private func routeMetadata(_ links: [[String: Any]]) throws {
            let body = try JSONSerialization.data(withJSONObject: ["Code": 1000, "Links": links])
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata", json: String(decoding: body, as: UTF8.self))
        }

        /// Every link ID in the metadata requests, in request order, including retries.
        private func metadataRequestLinkIDs() throws -> [String] {
            try StubURLProtocol.requests().filter { $0.path.contains("fetch_metadata") }.flatMap { request in
                let body = try #require(request.body)
                let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                return try #require(json["LinkIDs"] as? [String])
            }
        }

        /// A photos root key and one photo node key, so a repair can decrypt the attributes of an active photo.
        private struct LineageKeys: Sendable {
            let crypto = DriveCrypto(addressKeys: [], signers: [])
            let root: UnlockableKey
            private let node: UnlockableKey

            init() throws {
                _ = lineageCryptoReady
                root = UnlockableKey(
                    armored: try crypto.generateLockedNodeKey(passphrase: "root-pass"), passphrase: "root-pass")
                node = UnlockableKey(
                    armored: try crypto.generateLockedNodeKey(passphrase: "node-pass"), passphrase: "node-pass")
            }

            func activePhoto(_ linkID: String, attributes: String) throws -> [String: Any] {
                [
                    "LinkID": linkID, "Type": 2, "State": 1, "NodeKey": node.armored,
                    "NodePassphrase": try crypto.encrypt(text: node.passphrase, to: root),
                    "XAttr": try crypto.encrypt(text: attributes, to: node),
                    "FileProperties": ["ActiveRevision": ["Photo": [:] as [String: Any]]],
                ]
            }
        }

        /// The metadata of the next window downloads while the current window decrypts. Every photo is still asked
        /// for, the progress still advances window by window, and the build still finishes with its checkpoint.
        @Test func aFullBuildOverSeveralWindowsAsksForEveryPhotoInOrder() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            // 601 photos: one full window of 600 and one more. A page that is not exactly 500 long ends the list.
            let ids = (0..<601).map { String(format: "p%04d", $0) }
            let photos = ids.map { #"{"LinkID":"\#($0)","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}"# }
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"one"}"#)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/photos",
                json: #"{"Code":1000,"Photos":["# + photos.joined(separator: ",") + "]}")
            StubURLProtocol.route("POST /drive/shares/share1/links/fetch_metadata", json: #"{"Code":1000,"Links":[]}"#)
            let indexed = IndexedCounts()

            try await refresh(content: content, lineage: nil) { value in
                if value.phase == .indexing { indexed.append(value.completed) }
            }

            #expect(indexed.values == [0, 600, 601])
            let requested = StubURLProtocol.requests()
                .filter { $0.path == "/drive/shares/share1/links/fetch_metadata" }
                .flatMap { request -> [String] in
                    guard let body = request.body,
                        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    else { return [] }
                    return json["LinkIDs"] as? [String] ?? []
                }
            #expect(Set(requested) == Set(ids))
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "one")
        }

        private final class IndexedCounts: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [Int] = []
            var values: [Int] { lock.withLock { stored } }
            func append(_ value: Int) { lock.withLock { stored.append(value) } }
        }

        private func refresh(
            content: UploadIdentityManifestStore, lineage: UploadRemoteLineageIndexStore?,
            rebuildsMissingLineage: Bool = false, rootKey: UnlockableKey = .init(armored: "", passphrase: ""),
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { _ in }
        ) async throws {
            try await Self.refresh(
                content: content, lineage: lineage, rebuildsMissingLineage: rebuildsMissingLineage, rootKey: rootKey,
                progress: progress)
        }

        fileprivate static func refresh(
            content: UploadIdentityManifestStore, lineage: UploadRemoteLineageIndexStore?,
            rebuildsMissingLineage: Bool = false, rootKey: UnlockableKey = .init(armored: "", passphrase: ""),
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { _ in }
        ) async throws {
            try await ProtonUploadDedupeService.refreshRemoteContentIndex(
                material: material(rootKey: rootKey), session: makeSession(),
                crypto: DriveCrypto(addressKeys: [], signers: []),
                store: content, lineageStore: lineage, rebuildsMissingLineage: rebuildsMissingLineage,
                progress: progress)
        }
    }
}

/// One outcome that a test reads while the code under test still runs: nil until it is set.
private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    private var gaveUp = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var value: Bool? { lock.withLock { stored } }

    func set(_ value: Bool) {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stored = value
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    /// Returns when the outcome is set, without polling. The safety net only ends a wait that nothing else ended; the
    /// outcome then stays nil and the next expectation of the test fails.
    func wait() async {
        let safetyNet = Task {
            do { try await Task.sleep(for: testSafetyNet) } catch { return }
            giveUp()
        }
        defer { safetyNet.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if stored != nil || gaveUp { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func giveUp() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gaveUp = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }
}

/// The time that only ends a wait that nothing else ended. A mutation run shortens it with
/// `EM_TEST_SAFETY_NET_SECONDS`, so a broken production behavior fails in seconds instead of minutes.
private let testSafetyNet: Duration = .seconds(
    ProcessInfo.processInfo.environment["EM_TEST_SAFETY_NET_SECONDS"].flatMap { Int($0) } ?? 180)

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Holds a caller until the test opens it.
private actor HandlerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// The SDK's exact duplicate query, which these tests never reach.
private struct NoPhotoDuplicates: SDKPhotoDuplicatesClient {
    func findPhotoDuplicates(name: String, sha1: Data, cancellationToken: UUID) async throws -> [SDKNodeUid] { [] }
    func cancelFindPhotoDuplicates(cancellationToken: UUID) async throws {}
}

private actor BuildOrderLog {
    private(set) var entries: [String] = []
    private var gaveUp = false
    private var waiters: [(entry: String, continuation: CheckedContinuation<Bool, Never>)] = []

    func append(_ entry: String) {
        entries.append(entry)
        let (ready, rest) = (waiters.filter { $0.entry == entry }, waiters.filter { $0.entry != entry })
        waiters = rest
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    /// Returns true when `entry` is in the log, without polling; false once `giveUp()` ended the wait first.
    func waitFor(_ entry: String) async -> Bool {
        if entries.contains(entry) { return true }
        if gaveUp { return false }
        return await withCheckedContinuation { waiters.append((entry, $0)) }
    }

    /// Ends every wait for an entry that did not come, and every later one.
    func giveUp() {
        gaveUp = true
        let ended = waiters
        waiters = []
        ended.forEach { $0.continuation.resume(returning: false) }
    }
}

/// The sleeper of a gate whose first wait, the start limit, ends when the test calls `end()` and whose later waits
/// run `then`. The test can end the start limit while a build runs, whatever the speed of the machine.
private final class StartLimitHold: @unchecked Sendable {
    private let lock = NSLock()
    private let then: @Sendable (Duration) async throws -> Void
    private var firstWaitTaken = false
    private var ended = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(then: @escaping @Sendable (Duration) async throws -> Void) {
        self.then = then
    }

    func sleep(_ duration: Duration) async throws {
        let isFirst = lock.withLock { () -> Bool in
            defer { firstWaitTaken = true }
            return !firstWaitTaken
        }
        guard isFirst else { return try await then(duration) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let endedAlready = lock.withLock { () -> Bool in
                    if !ended { waiting = continuation }
                    return ended
                }
                if endedAlready { continuation.resume() }
            }
        } onCancel: {
            end()
        }
    }

    func end() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            ended = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

private actor PreparationLog {
    private(set) var steps: [UploadRemoteIndexPreparationProgress] = []
    func append(_ step: UploadRemoteIndexPreparationProgress) { steps.append(step) }
}
