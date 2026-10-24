import CryptoKit
import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveSDK
import SQLite3
import Testing
import UploadCore

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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let clock = ContinuousClock()
            func waitedFor(_ outcome: LockedOutcome) async throws -> Duration {
                let start = clock.now
                while outcome.value == nil, clock.now - start < .seconds(5) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return clock.now - start
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
            let begin = clock.now
            while listings() == 0, clock.now - begin < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(listings() == 1, "the build reached its library listing")
            window.cancel()
            let windowWait = try await waitedFor(windowCancelled)
            #expect(windowCancelled.value == true, "the expired window ended with a cancellation")
            #expect(windowWait < .seconds(2), "the expired window stopped waiting at once: \(windowWait)")

            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            let (later, laterCancelled) = preparation(reporting: laterProgress)
            // The later preparation reports loading just before it joins the running build.
            while laterProgress.value == nil, clock.now - begin < .seconds(20) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(listings() == 1, "a later preparation joins the running build")
            #expect(released.value == nil, "the metadata pass stays held while the build runs")
            later.cancel()
            let laterWait = try await waitedFor(laterCancelled)
            #expect(laterCancelled.value == true, "the joined preparation ended with a cancellation")
            #expect(laterWait < .seconds(2), "the joined preparation stopped waiting at once: \(laterWait)")

            // The end of the build, here through an invalidation, releases the metadata pass.
            await service.invalidateCachedRemoteState()
            let passWait = try await waitedFor(released)
            #expect(released.value == true, "the end of the build releases the metadata pass: \(passWait)")
            pass.cancel()
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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func listings() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count
            }
            let clock = ContinuousClock()
            let window = Task { try await service.prepareRemoteIndex { _ in } }
            let begin = clock.now
            while listings() == 0, clock.now - begin < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
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
            let stopped = clock.now
            while ended.value == nil, clock.now - stopped < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(ended.value == true, "the shutdown ended the running build")
            shutdown.cancel()
            // The cancelled build ended, so the metadata pass that the cancelled preparation left held is released.
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }
            let shut = clock.now
            while released.value == nil, clock.now - shut < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
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
            let asked = clock.now
            while afterShutdown.value == nil, clock.now - asked < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
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
            let clock = ContinuousClock()
            let pass = Task { try await service.prepareRemoteIndex { _ in } }
            let begin = clock.now
            while listings() == 0, clock.now - begin < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            func eventReads() -> Int {
                StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/events/one") }.count
            }
            let clock = ContinuousClock()
            // An asset proof starts the shorter refresh of the events, which hangs.
            let proof = Task {
                try await service.findRemoteAssetProofs(for: [
                    UploadBackupExternalIdentity(identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
                ])
            }
            let begin = clock.now
            while eventReads() == 0, clock.now - begin < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(eventReads() == 1, "the shorter refresh reads the events")
            // The preparation needs the lineage rebuild, waits for the running refresh and then stops.
            let loading = LockedOutcome()
            let preparation = Task { try await service.prepareRemoteIndex { _ in loading.set(true) } }
            while loading.value == nil, clock.now - begin < .seconds(20) {
                try await Task.sleep(for: .milliseconds(10))
            }
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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let released = LockedOutcome()
            let pass = Task {
                await gate.wait()
                released.set(true)
            }
            defer { pass.cancel() }
            let clock = ContinuousClock()
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
            let begin = clock.now
            while reachedTheBuild.value == nil, clock.now - begin < .seconds(10) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(reachedTheBuild.value == true, "L runs and waits in the handler")
            preparation.cancel()
            _ = await preparation.result
            await service.invalidateCachedRemoteState()
            let requestsBeforeN = StubURLProtocol.requests().count
            let newer = Task {
                try await service.findRemoteAssetProofs(for: [
                    UploadBackupExternalIdentity(identifier: "asset", modificationDate: Date(timeIntervalSince1970: 0))
                ])
            }
            let started = clock.now
            while StubURLProtocol.requests().count == requestsBeforeN, clock.now - started < .seconds(10) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await service.unfinishedRemoteContentIndexBuildCount == 2, "L and N run")

            await holdsTheBuild.open()
            let ending = clock.now
            while await service.unfinishedRemoteContentIndexBuildCount > 1, clock.now - ending < .seconds(10) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await service.unfinishedRemoteContentIndexBuildCount == 1, "L ended and N still runs")
            try await body(service, gate, released)
            await service.shutdown()
            newer.cancel()
            _ = await newer.result
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
            // The build outlasts the start limit, which applies only until a build starts.
            let gate = TimelineMetadataStartGate(startLimit: .seconds(1), limit: .seconds(60))
            let service = makeService(content: content, lineage: lineage, firstBuildGate: gate)
            let reconciliation = TimelineMetadataReconciliation(startGate: gate)
            let events = BuildOrderLog()
            reconciliation.schedule(timelineInventory) { _ in await events.append("metadata pass") }

            try await service.prepareRemoteIndex { step in
                // The last progress comes a moment after the build ends; the pass still starts only after it.
                if step.phase == .ready { try? await Task.sleep(for: .milliseconds(500)) }
                await events.append("build \(step.phase)")
                if step.phase == .indexing { try? await Task.sleep(for: .milliseconds(1_500)) }
            }
            #expect(await passStart(events, reconciliation) != nil)

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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
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
            let gate = TimelineMetadataStartGate(startLimit: .seconds(20), limit: .seconds(20))
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

            #expect(await passStart(events, reconciliation) != nil, "the failed build must release the pass")
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
                let gate = TimelineMetadataStartGate(startLimit: .seconds(20), limit: .seconds(20))
                _ = makeService(content: content, lineage: lineage, firstBuildGate: gate)
                let reconciliation = TimelineMetadataReconciliation(startGate: gate)
                let events = BuildOrderLog()

                reconciliation.schedule(timelineInventory) { _ in await events.append("metadata pass") }

                let waited = await passStart(events, reconciliation)
                #expect(waited.map { $0 < .seconds(5) } == true, "\(mode): a later launch must not hold the pass")
            }
        }

        /// Waits at most ten seconds for the pass, then retires the scheduler so a held pass cannot outlive the test.
        private func passStart(
            _ events: BuildOrderLog, _ reconciliation: TimelineMetadataReconciliation
        ) async -> Duration? {
            let clock = ContinuousClock()
            let begin = clock.now
            var started: Duration?
            while started == nil, clock.now - begin < .seconds(10) {
                if await events.entries.contains("metadata pass") {
                    started = clock.now - begin
                } else {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            reconciliation.retire()
            await reconciliation.waitForCurrentPass()
            return started
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
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

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
    func append(_ entry: String) { entries.append(entry) }
}

private actor PreparationLog {
    private(set) var steps: [UploadRemoteIndexPreparationProgress] = []
    func append(_ step: UploadRemoteIndexPreparationProgress) { steps.append(step) }
}
