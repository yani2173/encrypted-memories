import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite struct TrashedRelatedPhotoStateTests {
        @Test(arguments: [
            #"{"LinkID":"main","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#,
            #"{"LinkID":"main","Type":2,"State":1}"#,
        ])
        func anUnknownMainStateAfterARestoreErrorReleasesNoFrame(mainJSON: String) async throws {
            try await checkReread(mainJSON, expectedRestores: [["main"]])
        }

        @Test func anExplicitActiveMainAfterARestoreErrorStillReleasesItsFrame() async throws {
            try await checkReread(
                #"{"LinkID":"main","Type":2,"State":1,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#,
                expectedRestores: [["main"], ["frame"]])
        }

        @Test(arguments: [
            "",
            #"{"LinkID":"main","Type":2,"State":2,"FileProperties":{"ActiveRevision":{"Photo":{}}}}"#,
        ])
        func anAbsentOrTrashedMainAfterARestoreErrorReleasesNoFrame(mainJSON: String) async throws {
            try await checkReread(mainJSON, expectedRestores: [["main"]])
        }

        private func checkReread(_ mainJSON: String, expectedRestores: [[String]]) async throws {
            let main = PhotoUID(volumeID: "own-volume", nodeID: "main")
            let frame = PhotoUID(volumeID: "own-volume", nodeID: "frame")
            let fixture = try await RestoreWithoutTrashListingTests.Fixture(
                frameTrashTime: 1001, checkedCandidates: [main: [frame]])
            defer { fixture.close() }
            let before = #"""
                {"Code":1000,"Links":[
                  {"LinkID":"main","Type":2,"State":2,"Trashed":1000,
                   "FileProperties":{"ActiveRevision":{"Photo":{}}}},
                  {"LinkID":"frame","Type":2,"State":2,"Trashed":1001,
                   "FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}}
                ]}
                """#
            let frameJSON =
                #"{"LinkID":"frame","Type":2,"State":2,"Trashed":1001,"FileProperties":{"ActiveRevision":{"Photo":{"MainPhotoLinkID":"main"}}}}"#
            let after = [mainJSON, frameJSON].filter { !$0.isEmpty }.joined(separator: ",")
            StubURLProtocol.routeSequence(
                "POST /drive/shares/share/links/fetch_metadata",
                responses: [(200, before), (200, #"{"Code":1000,"Links":[\#(after)]}"#)])
            StubURLProtocol.fail(
                "PUT /drive/v2/volumes/own-volume/trash/restore_multiple", code: NSURLErrorNetworkConnectionLost)

            let error = await #expect(throws: URLError.self) {
                try await fixture.bridge.restore([main])
            }

            #expect(error?.code == .networkConnectionLost, "the original restore error stays visible")
            #expect(
                fixture.metadataReads() == (expectedRestores.count == 2 ? 3 : 2),
                "fresh main/frame proof and ambiguous frame response reconciliation")
            #expect(try fixture.restoredLinkIDs() == expectedRestores)
        }
    }
}
