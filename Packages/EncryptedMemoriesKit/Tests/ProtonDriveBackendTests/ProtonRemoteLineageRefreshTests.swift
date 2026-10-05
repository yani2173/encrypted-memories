import CryptoKit
import Foundation
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
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
        /// A lineage read then asks for one full build, which fills both indexes at the same event.
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

        private func checkpoint(_ eventID: String) -> UploadRemoteContentIndexCheckpoint {
            .init(eventID: eventID, refreshedAt: Date())
        }

        private func routeEmptyEvents(from: String, to: String) {
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/\(from)",
                json: #"{"Code":1000,"EventID":"\#(to)","More":0,"Refresh":0,"Events":[]}"#)
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
            let session = DriveSession(
                session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: FileManager.default.temporaryDirectory,
                urlProtocolClasses: [StubURLProtocol.self])
            try await ProtonUploadDedupeService.refreshRemoteContentIndex(
                material: .init(
                    context: .init(volumeID: "vol1", shareID: "share1", rootLinkID: "root1"),
                    rootKey: rootKey, hashKey: Data(), epoch: "epoch"),
                session: session, crypto: DriveCrypto(addressKeys: [], signers: []),
                store: content, lineageStore: lineage, rebuildsMissingLineage: rebuildsMissingLineage,
                progress: progress)
        }
    }
}
