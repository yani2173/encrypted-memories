import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite
    struct DriveSessionPhotosListTests {
        @Test
        func streamsCursorPagesWithoutBuildingTheListInTheSession() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json:
                            #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]},{"LinkID":"p2","CaptureTime":2,"Tags":[],"RelatedPhotos":[]}] }"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p3","CaptureTime":3,"Tags":[],"RelatedPhotos":[]}] }"#
                    ),
                ]
            )

            var pages: [[String]] = []
            try await makeSessionForPhotosListTests().forEachPhotosListPage(
                volumeID: "vol1",
                pageSize: 2
            ) { page in
                pages.append(page.map(\.linkID))
            }

            #expect(pages == [["p1", "p2"], ["p3"]])
            let requests = StubURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests[0].path.contains("PageSize=2"))
            #expect(requests[1].path.contains("PreviousPageLastLinkID=p2"))
        }

        @Test func repeatedFullPageCursorThrowsTypedError() async throws {
            // A repeated PreviousPageLastLinkID indicates a full-page cursor reuse ; must fail with a typed error.
            // The trailing empty page is a safety valve so the unfixed code terminates (and fails) instead of hanging.
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (status: 200, json: #"{"Code":1000,"Photos":[]}"#),
                ]
            )

            await #expect(throws: DrivePaginationError.self) {
                try await makeSessionForPhotosListTests().forEachPhotosListPage(
                    volumeID: "vol1",
                    pageSize: 1
                ) { _ in }
            }
        }

        @Test func abaCursorCycleThrowsTypedError() async throws {
            // An A-B-A cycle: the last link of a full page repeats an already-used cursor.
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"a","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"b","CaptureTime":2,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"a","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (status: 200, json: #"{"Code":1000,"Photos":[]}"#),
                ]
            )

            await #expect(throws: DrivePaginationError.repeatedPhotosCursor("a")) {
                try await makeSessionForPhotosListTests().forEachPhotosListPage(
                    volumeID: "vol1",
                    pageSize: 1
                ) { _ in }
            }
        }

        // MARK: Album listing

        private static let albumRoute = "GET /drive/photos/volumes/vol1/albums/album1/children"

        private static func albumPage(
            _ linkID: String, more: Bool, anchor: String? = nil
        ) -> (status: Int, json: String) {
            let anchorField = anchor.map { #","AnchorID":"\#($0)""# } ?? ""
            return (
                status: 200,
                json:
                    #"{"Code":1000,"Photos":[{"LinkID":"\#(linkID)","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}],"More":\#(more)"#
                    + anchorField + "}"
            )
        }

        @Test func albumPagesFollowTheirAnchorsInOrder() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                Self.albumRoute,
                responses: [
                    Self.albumPage("a", more: true, anchor: "x"),
                    Self.albumPage("b", more: true, anchor: "y"),
                    Self.albumPage("c", more: false),
                ])

            let entries = try await makeSessionForPhotosListTests().fetchAlbumPhotos(
                volumeID: "vol1", albumLinkID: "album1")

            #expect(entries.map(\.linkID) == ["a", "b", "c"])
            #expect(StubURLProtocol.requests().count == 3)
        }

        @Test func anAlbumPageThatRepeatsAnAnchorFailsInsteadOfLooping() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                Self.albumRoute,
                responses: [
                    Self.albumPage("a", more: true, anchor: "x"),
                    Self.albumPage("b", more: true, anchor: "x"),
                    Self.albumPage("c", more: false),
                ])

            await #expect(throws: DrivePaginationError.repeatedAlbumAnchor("x")) {
                _ = try await makeSessionForPhotosListTests().fetchAlbumPhotos(
                    volumeID: "vol1", albumLinkID: "album1")
            }
            #expect(StubURLProtocol.requests().count == 2, "the repeated anchor is never requested a third time")
        }

        @Test func invalidPageSizeZeroThrowsWithoutNetwork() async throws {
            StubURLProtocol.reset()
            // pageSize=0 should fail before making any network request.
            await #expect(throws: DrivePaginationError.self) {
                try await makeSessionForPhotosListTests().forEachPhotosListPage(
                    volumeID: "vol1",
                    pageSize: 0
                ) { _ in }
            }
            #expect(StubURLProtocol.requests().isEmpty, "no network call for invalid pageSize")
        }

        @Test func emptyTerminalPageStopsGracefully() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (status: 200, json: #"{"Code":1000,"Photos":[]}"#),
                ]
            )

            var collected: [String] = []
            try await makeSessionForPhotosListTests().forEachPhotosListPage(
                volumeID: "vol1",
                pageSize: 1
            ) { page in
                collected.append(contentsOf: page.map(\.linkID))
            }

            #expect(collected == ["p1"])
        }

        @Test func cancellationBeforeFetchPropagatesCancellationError() async {
            await #expect(throws: CancellationError.self) {
                try await makeSessionForPhotosListTests().forEachPhotosListPage(
                    volumeID: "vol1",
                    pageSize: 1
                ) { _ in
                    throw CancellationError()
                }
            }
        }

        @Test func cancellationAfterFetchPropagatesCancellationError() async {
            StubURLProtocol.reset()
            StubURLProtocol.routeSequence(
                "GET /drive/volumes/vol1/photos",
                responses: [
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p1","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                    (
                        status: 200,
                        json: #"{"Code":1000,"Photos":[{"LinkID":"p2","CaptureTime":2,"Tags":[],"RelatedPhotos":[]}]}"#
                    ),
                ]
            )

            await #expect(throws: CancellationError.self) {
                try await makeSessionForPhotosListTests().forEachPhotosListPage(
                    volumeID: "vol1",
                    pageSize: 1
                ) { _ in
                    throw CancellationError()
                }
            }
        }
    }
}

private func makeSessionForPhotosListTests() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-photos-list-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}
