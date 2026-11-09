import Foundation
import PhotosCore
import SQLite3
import Testing
import UploadCore

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite struct TrashedSeriesRestoreRetryTests {
        @Test(arguments: [false, true])
        func aFailedFrameCheckLeavesTheMainInTrashAndReportsTheExistingError(knownFrames: Bool) async throws {
            let main = PhotoUID(volumeID: "own-volume", nodeID: "main")
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001,
                checkedCandidates: knownFrames ? [main: [PhotoUID(volumeID: "own-volume", nodeID: "frame")]] : nil)
            defer { fixture.close() }
            StubURLProtocol.fail(
                knownFrames
                    ? "POST /drive/shares/share/links/fetch_metadata" : "GET /drive/volumes/own-volume/trash",
                code: NSURLErrorNetworkConnectionLost)

            let error = await #expect(throws: URLError.self) {
                try await fixture.bridge.restore([main])
            }

            #expect(error?.code == .networkConnectionLost, "Restore keeps the existing discovery error")
            #expect(try fixture.restoredLinkIDs().isEmpty, "the main stays in trash until its frame check succeeds")
        }

        @Test func aReadableFrameCheckStillRestoresTheMainAndItsEligibleFrame() async throws {
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(frameTrashTime: 1001)
            defer { fixture.close() }

            try await fixture.bridge.restore([PhotoUID(volumeID: "own-volume", nodeID: "main")])

            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"]])
        }
        private static let metadataRoute = "POST /drive/shares/share/links/fetch_metadata"
        private static let restoreRoute = "PUT /drive/v2/volumes/own-volume/trash/restore_multiple"
        private let main = PhotoUID(volumeID: "own-volume", nodeID: "main")

        private func metadata(
            mainState: Int = 1, mainTrash: Int64 = 1000,
            frames: [(String, Int, Int64, String)] = [("frame", 2, 1001, "main")]
        ) -> String {
            let rows = frames.map { id, state, trash, relationship in
                "{\"LinkID\":\"\(id)\",\"Type\":2,\"State\":\(state),\"Trashed\":\(trash),\"FileProperties\":{\"ActiveRevision\":{\"Photo\":{\"MainPhotoLinkID\":\"\(relationship)\"}}}}"
            }
            return
                "{\"Code\":1000,\"Links\":[{\"LinkID\":\"main\",\"Type\":2,\"State\":\(mainState),\"Trashed\":\(mainTrash),\"FileProperties\":{\"ActiveRevision\":{\"Photo\":{}}}},"
                + rows.joined(separator: ",") + "]}"
        }

        private func seeded(_ directory: URL, frames: [String] = ["frame"]) throws -> TrashedSeriesRestoreRecord {
            let journal = try #require(
                TrashedSeriesRestoreJournal(url: directory.appendingPathComponent(TrashedSeriesRestoreJournal.fileName))
            )
            defer { journal.close() }
            let record = TrashedSeriesRestoreRecord(
                generation: UUID(), main: main, mainTrashTime: 1000,
                frames: frames.map {
                    .init(uid: PhotoUID(volumeID: "own-volume", nodeID: $0), mainPhotoLinkID: "main", trashTime: 1001)
                },
                retryAt: .distantPast)
            try journal.record([record])
            return record
        }

        private func records(_ directory: URL) throws -> [TrashedSeriesRestoreRecord] {
            let journal = try #require(
                TrashedSeriesRestoreJournal(url: directory.appendingPathComponent(TrashedSeriesRestoreJournal.fileName))
            )
            defer { journal.close() }
            return try journal.records()
        }

        private func waitUntil(_ condition: () throws -> Bool) async throws {
            for _ in 0..<500 {
                if try condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try condition())
        }

        @Test func aFailedFrameRestoreSurvivesRealAccountCloseAndReconstruction() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let first = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.fail(Self.restoreRoute, code: NSURLErrorNetworkConnectionLost, afterResponses: 1)
            #expect(await first.effects.restore([main]) == .done)
            await first.bridge.shutdown()
            var saved = try #require(records(directory.url).first)
            #expect(saved.frames.map(\.uid.nodeID) == ["frame"])
            saved.retryAt = .distantPast
            let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
            try journal.update(saved)
            journal.close()

            let reopened = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(Self.metadataRoute, json: metadata())
            StubURLProtocol.route(
                Self.restoreRoute, json: #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":1000}}]}"#)
            await reopened.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).isEmpty }
            await reopened.bridge.shutdown()
            #expect(try records(directory.url).isEmpty)
            #expect(try reopened.restoredLinkIDs() == [["frame"]])
        }

        @Test func aPartialFrameBatchKeepsOnlyUnresolvedDuties() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url, frames: ["first", "second"])
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.routeSequence(
                Self.metadataRoute,
                responses: [
                    (200, metadata(frames: [("first", 2, 1001, "main"), ("second", 2, 1001, "main")])),
                    (200, metadata(frames: [("first", 1, 1001, "main"), ("second", 2, 1001, "main")])),
                ])
            StubURLProtocol.route(
                Self.restoreRoute,
                json:
                    #"{"Code":1000,"Responses":[{"LinkID":"first","Response":{"Code":1000}},{"LinkID":"second","Response":{"Code":2001}}]}"#
            )
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).first?.frames.map(\.uid.nodeID) == ["second"] }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs() == [["first", "second"]])
        }

        @Test func aMainAppliedBeforeItsResponseWasLostResumesFramesAfterReconstruction() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let first = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.hang(Self.restoreRoute)
            let restoring = Task { try await first.bridge.restore([main]) }
            try await waitUntil { try first.restoredLinkIDs() == [["main"]] }
            // Model process loss after the server applied main, without a response or an in-memory retry list.
            restoring.cancel()
            _ = await restoring.result
            await first.bridge.shutdown()
            #expect(try records(directory.url).count == 1)
            var saved = try #require(records(directory.url).first)
            saved.retryAt = .distantPast
            let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
            try journal.update(saved)
            journal.close()
            let reopened = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(Self.metadataRoute, json: metadata())
            StubURLProtocol.route(
                Self.restoreRoute, json: #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":1000}}]}"#)
            await reopened.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).isEmpty }
            await reopened.bridge.shutdown()
            #expect(try records(directory.url).isEmpty)
            #expect(try reopened.restoredLinkIDs() == [["frame"]])
        }

        @Test func aJournalWriteRefusalSendsNoMainRestore() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            try Data("unavailable operational journal".utf8).write(to: directory.database)
            let before = try Data(contentsOf: directory.database)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            await #expect(throws: (any Error).self) { try await fixture.bridge.restore([main]) }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().isEmpty)
            #expect(try Data(contentsOf: directory.database) == before)
        }

        @Test(arguments: ["network", "undecodable", "incomplete", "implicit", "stillTrashed"])
        func unknownOrStillTrashedMainRetainsTheDuty(kind: String) async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let original = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            switch kind {
            case "network": StubURLProtocol.fail(Self.metadataRoute, code: NSURLErrorNetworkConnectionLost)
            case "undecodable": StubURLProtocol.route(Self.metadataRoute, json: "invalid")
            case "incomplete": StubURLProtocol.route(Self.metadataRoute, json: #"{"Code":1000,"Links":[],"More":true}"#)
            case "implicit":
                StubURLProtocol.route(
                    Self.metadataRoute,
                    json: #"{"Code":1000,"Links":[{"LinkID":"main","FileProperties":{"ActiveRevision":{"Photo":{}}}}]}"#
                )
            default: StubURLProtocol.route(Self.metadataRoute, json: metadata(mainState: 2))
            }
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).first?.attempts == 1 }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().isEmpty)
            #expect(try records(directory.url).first?.generation == original.generation)
            #expect(try records(directory.url).first?.frames == original.frames)
        }

        @Test(arguments: [false, true])
        func definiteGoneSettlesTheMatchingDuty(mainGone: Bool) async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(
                Self.metadataRoute,
                json: mainGone
                    ? #"{"Code":1000,"Links":[]}"# : metadata(frames: []).replacingOccurrences(of: ",]", with: "]"))
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).isEmpty }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test(arguments: [false, true])
        func aLaterDeliberateTrashEndsTheOldRecordWithoutRestoringFrames(mainActive: Bool) async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(Self.metadataRoute, json: metadata(mainState: mainActive ? 1 : 2, mainTrash: 2000))
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).isEmpty }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test func accountCloseCancelsAndJoinsTheWorkerAndSendsNoFurtherRequests() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.hang(Self.metadataRoute)
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { fixture.metadataReads() > 0 }
            await fixture.bridge.shutdown()
            let count = StubURLProtocol.requests().count
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            #expect(StubURLProtocol.requests().count == count)
            #expect(try fixture.restoredLinkIDs().isEmpty)
            #expect(try records(directory.url).count == 1)
        }

        @Test(arguments: [
            "partial", "missingLinks", "missingState", "unknownState", "missingPhoto", "omittedFrame", "duplicate",
        ])
        func incompletePreflightNeverSendsAMainRestore(kind: String) async throws {
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001,
                checkedCandidates: [main: [PhotoUID(volumeID: "own-volume", nodeID: "frame")]])
            defer { fixture.close() }
            let valid = metadata(mainState: 2)
            let body: String
            switch kind {
            case "partial":
                body = valid.replacingOccurrences(of: "{\"Code\":1000", with: "{\"More\":true,\"Code\":1000")
            case "missingLinks": body = #"{"Code":1000}"#
            case "missingState": body = valid.replacingOccurrences(of: "\"State\":2,", with: "")
            case "unknownState": body = valid.replacingOccurrences(of: "\"State\":2", with: "\"State\":7")
            case "missingPhoto": body = valid.replacingOccurrences(of: "\"Photo\":{}", with: "\"Unknown\":{}")
            case "duplicate":
                body = valid.replacingOccurrences(
                    of: "\"Links\":[",
                    with:
                        "\"Links\":[{\"LinkID\":\"main\",\"State\":2,\"Trashed\":1000,\"FileProperties\":{\"ActiveRevision\":{\"Photo\":{}}}},"
                )
            default: body = metadata(mainState: 2, frames: []).replacingOccurrences(of: ",]", with: "]")
            }
            StubURLProtocol.route(Self.metadataRoute, json: body)
            await #expect(throws: (any Error).self) { try await fixture.bridge.restore([main]) }
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test(arguments: ["timestamp", "relationship", "alreadyActive"])
        func changedOrAlreadyActiveFrameEndsOnlyItsOldDuty(kind: String) async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(
                Self.metadataRoute,
                json: metadata(frames: [
                    (
                        "frame", kind == "alreadyActive" ? 1 : 2, kind == "timestamp" ? 2000 : 1001,
                        kind == "relationship" ? "other" : "main"
                    )
                ]))
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).isEmpty }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test func aRefusedDurableWriteSendsNoMainRestore() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            // Create and close the actual schema before holding the competing writer.
            let journal = try #require(TrashedSeriesRestoreJournal(url: directory.database))
            journal.close()
            var blocker: OpaquePointer?
            #expect(sqlite3_open(directory.database.path, &blocker) == SQLITE_OK)
            defer { sqlite3_close(blocker) }
            #expect(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
            await #expect(throws: (any Error).self) { try await fixture.bridge.restore([main]) }
            #expect(try fixture.restoredLinkIDs().isEmpty)
            #expect(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
            await fixture.bridge.shutdown()
        }
        @Test func anOrdinaryTimerRetryRestoresOnlyTheOwedFrame() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url,
                seriesRestoreRetry: .init(baseDelay: 0.01, maxDelay: 0.02))
            StubURLProtocol.routeSequence(
                Self.restoreRoute,
                responses: [
                    (200, #"{"Code":1000,"Responses":[{"LinkID":"main","Response":{"Code":1000}}]}"#),
                    (200, #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":2001}}]}"#),
                    (200, #"{"Code":1000,"Responses":[{"LinkID":"frame","Response":{"Code":1000}}]}"#),
                ])
            #expect(await fixture.effects.restore([main]) == .done)
            try await waitUntil { try records(directory.url).isEmpty }
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs() == [["main"], ["frame"], ["frame"]])
        }

        @Test func aLocalRepeatTrashEndsTheOldGenerationEvenWithinTheSameTimestampSecond() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(
                "POST /drive/v2/volumes/own-volume/trash_multiple",
                json: #"{"Code":1000,"Responses":[{"LinkID":"main","Response":{"Code":1000}}]}"#)
            try await fixture.bridge.trash([main])
            #expect(try records(directory.url).isEmpty)
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            await fixture.bridge.shutdown()
            #expect(try fixture.restoredLinkIDs().allSatisfy { $0 == ["main"] })
            #expect(StubURLProtocol.requests().filter { $0.path.contains("restore_multiple") }.isEmpty)
        }

        @Test(arguments: ["implicit", "missingTrashTime"])
        func anUnknownFrameKeepsItsDuty(kind: String) async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            let original = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            let frame =
                kind == "implicit"
                ? #"{"LinkID":"frame","State":2,"Trashed":1001}"#
                : #"{"LinkID":"frame","State":2,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}}"#
            let activeMain = #"{"LinkID":"main","State":1,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#
            StubURLProtocol.route(Self.metadataRoute, json: #"{"Code":1000,"Links":[\#(activeMain),\#(frame)]}"#)
            await fixture.bridge.startTrashedSeriesRestoreReplay()
            try await waitUntil { try records(directory.url).first?.attempts == 1 }
            await fixture.bridge.shutdown()
            #expect(try records(directory.url).first?.frames == original.frames)
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }
        @Test(arguments: [
            #"{"Code":1000,"Trash":[],"More":true}"#,
            #"{"Code":1000}"#,
            #"{"Code":2001,"Trash":[]}"#,
        ])
        func anIncompleteTrashPageNeverGrantsAnEmptyFrameSet(body: String) async throws {
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            StubURLProtocol.route("GET /drive/volumes/own-volume/trash", json: body)
            await #expect(throws: (any Error).self) { try await fixture.bridge.restore([main]) }
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }
        @Test func aTolerantDisplayListingNeverCertifiesRestoreDiscovery() async throws {
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(frameTrashTime: 1001)
            defer { fixture.close() }
            StubURLProtocol.route(Self.metadataRoute, json: #"{"Code":1000,"Links":[{"LinkID":"main","Type":2}]}"#)
            let sections = try await fixture.bridge.timeline(filter: .trash)
            #expect(sections.flatMap(\.items).map(\.uid) == [main])
            await #expect(throws: (any Error).self) { try await fixture.bridge.restore([main]) }
            #expect(fixture.listings() == 2, "Restore repeats the unchecked display discovery")
            #expect(try fixture.restoredLinkIDs().isEmpty)
        }

        @Test func aForegroundObservationOfANewerMainTrashEndsTheOldDutyBeforeRestore() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            _ = try seeded(directory.url)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.routeSequence(
                Self.metadataRoute,
                responses: [
                    (200, metadata(mainState: 2, mainTrash: 2000)),
                    (200, metadata(mainState: 2, mainTrash: 2000)),
                    (200, metadata()),
                ])
            try await fixture.bridge.restore([main])
            await fixture.bridge.shutdown()
            #expect(try records(directory.url).isEmpty)
            #expect(try fixture.restoredLinkIDs() == [["main"]])
        }
        @Test func anUnavailableJournalRefusesLocalTrashBeforeSendingItsRequest() async throws {
            let directory = try TrashedSeriesRestoreJournalTests.Directory()
            defer { directory.remove() }
            try Data("unavailable operational journal".utf8).write(to: directory.database)
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, ownedDirectory: directory.url)
            StubURLProtocol.route(
                "POST /drive/v2/volumes/own-volume/trash_multiple",
                json: #"{"Code":1000,"Responses":[{"LinkID":"main","Response":{"Code":1000}}]}"#)
            await #expect(throws: (any Error).self) { try await fixture.bridge.trash([main]) }
            await fixture.bridge.shutdown()
            #expect(StubURLProtocol.requests().filter { $0.path.contains("trash_multiple") }.isEmpty)
        }
    }
}
