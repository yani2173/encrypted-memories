import Foundation
import Testing
import UploadCore

@testable import AlbumSyncCore

@MainActor @Suite struct AlbumSyncLastRunStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-last-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let items = [
        BackupFailedItem(
            id: "album/a", filename: "a.heic", reason: "attach reason", isPermanent: false, isRetryable: true,
            category: .userResolvable),
        BackupFailedItem(
            id: "queue-b", filename: "b.heic", reason: "gone reason", isPermanent: true, issue: .sourceMissing),
    ]

    private func relaunch(_ directory: URL) async -> AlbumSyncLastRunStore {
        let store = AlbumSyncLastRunStore(directory: directory)
        await store.load()
        return store
    }

    @Test func listSurvivesARelaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        await store.flush()

        let relaunched = await relaunch(directory)

        let loaded = relaunched.items(albumID: "L1")
        #expect(loaded.map(\.id) == ["album/a", "queue-b"])
        #expect(loaded.map(\.filename) == ["a.heic", "b.heic"])
        #expect(loaded.map(\.reason) == ["attach reason", "gone reason"])
        #expect(loaded.map(\.category) == [.userResolvable, .permanent])
        #expect(loaded.map(\.isPermanent) == [false, true])
        #expect(relaunched.items(albumID: "L2").isEmpty)
    }

    @Test func emptyListClearsTheAlbumAndRemovesTheFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        await store.flush()
        let url = directory.appendingPathComponent(AlbumSyncLastRunStore.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.record([], albumID: "L1")
        await store.flush()

        #expect(store.items(albumID: "L1").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await relaunch(directory).items(albumID: "L1").isEmpty)
    }

    @Test func clearingOneAlbumKeepsTheOthers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        store.record([items[0]], albumID: "L2")

        store.record([], albumID: "L1")
        await store.flush()

        let relaunched = await relaunch(directory)
        #expect(relaunched.items(albumID: "L1").isEmpty)
        #expect(relaunched.items(albumID: "L2").map(\.id) == ["album/a"])
    }

    @Test func unreadableFileMeansNoLists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent(AlbumSyncLastRunStore.fileName))

        let store = await relaunch(directory)

        #expect(store.items(albumID: "L1").isEmpty)
        // The next finished run rewrites the cache.
        store.record(items, albumID: "L1")
        await store.flush()
        #expect(await relaunch(directory).items(albumID: "L1").count == 2)
    }

    @Test func aListRecordedBeforeTheFileLoadsWinsAndKeepsTheOtherAlbums() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = await relaunch(directory)
        earlier.record(items, albumID: "L1")
        earlier.record(items, albumID: "L2")
        earlier.record(items, albumID: "L3")
        await earlier.flush()

        let store = AlbumSyncLastRunStore(directory: directory)
        // Runs finish before the file has loaded: one list changes, one clears.
        store.record([items[1]], albumID: "L1")
        store.record([], albumID: "L2")
        await store.flush()
        // Until the load, the file keeps every album: an exit now loses no list.
        #expect(await relaunch(directory).items(albumID: "L3").count == 2)
        await store.load()
        await store.flush()

        #expect(store.items(albumID: "L1").map(\.id) == ["queue-b"])
        let relaunched = await relaunch(directory)
        #expect(relaunched.items(albumID: "L1").map(\.id) == ["queue-b"])
        #expect(relaunched.items(albumID: "L2").isEmpty)
        #expect(relaunched.items(albumID: "L3").count == 2, "an album that only the file knew stays")
    }

    @Test func anAlbumKeepsAtMostTheListLimit() throws {
        let store = AlbumSyncLastRunStore(directory: try makeDirectory())
        let many = (0..<(AlbumSyncLastRunStore.itemLimit + 5)).map {
            BackupFailedItem(id: "\($0)", filename: "\($0).heic", reason: "r", isPermanent: false)
        }

        store.record(many, albumID: "L1")

        #expect(store.items(albumID: "L1").count == AlbumSyncLastRunStore.itemLimit)
        #expect(store.items(albumID: "L1").first?.id == "0")
    }

    @Test func sourcesSurviveARelaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourced = [
            BackupFailedItem(
                id: "album/a", filename: "a.heic", reason: "attach reason", isPermanent: false, isRetryable: true,
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-a"),
                category: .userResolvable),
            BackupFailedItem(
                id: "queue-b", filename: "b.heic", reason: "gone reason", isPermanent: true, issue: .sourceMissing,
                source: UploadSourceIdentity(
                    kind: .photoLibraryAsset, identifier: "asset-b", resource: .livePairedVideo)),
        ]
        let store = await relaunch(directory)
        store.record(sourced + [items[0]], albumID: "L1")
        await store.flush()

        let loaded = await relaunch(directory).items(albumID: "L1")

        #expect(loaded.map(\.id) == ["album/a", "queue-b", "album/a"])
        #expect(loaded.map(\.source) == [sourced[0].source, sourced[1].source, nil])
    }

    /// The released writer stored seven fields per row; this fixture is generated from a legacy struct
    /// with exactly those fields, so its bytes are the bytes the released writer produced.
    @Test func anOldFileWithoutSourcesKeepsEveryRow() async throws {
        struct LegacyStoredItem: Codable {
            var id: String
            var filename: String
            var reason: String
            var category: String
            var issue: BackupIssueKind
            var isPermanent: Bool
            var isRetryable: Bool
        }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = [
            "L1": [
                LegacyStoredItem(
                    id: "album/a", filename: "a.heic", reason: "attach reason", category: "userResolvable",
                    issue: .unknown, isPermanent: false, isRetryable: true),
                LegacyStoredItem(
                    id: "queue-b", filename: "b.heic", reason: "gone reason", category: "permanent",
                    issue: .sourceMissing, isPermanent: true, isRetryable: false),
            ]
        ]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: directory.appendingPathComponent(AlbumSyncLastRunStore.fileName))

        let loaded = await relaunch(directory).items(albumID: "L1")

        #expect(loaded.map(\.id) == ["album/a", "queue-b"])
        #expect(loaded.map(\.filename) == ["a.heic", "b.heic"])
        #expect(loaded.compactMap(\.source).isEmpty)
    }

    /// A `source` value the reader cannot decode must not drop the row, its neighbors, or the album.
    private func assertEveryRowSurvives(sourceJSON: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {"L1": [
                \(Self.rowJSON(id: "album/a", source: nil)),
                \(Self.rowJSON(id: "album/b", source: sourceJSON)),
                \(Self.rowJSON(id: "album/c", source: nil))
            ],
            "L2": [\(Self.rowJSON(id: "queue-d", source: sourceJSON))]}
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent(AlbumSyncLastRunStore.fileName))

        let relaunched = await relaunch(directory)
        let l1 = relaunched.items(albumID: "L1")

        #expect(l1.map(\.id) == ["album/a", "album/b", "album/c"], "the whole album must survive")
        #expect(l1.map(\.filename) == ["album/a.heic", "album/b.heic", "album/c.heic"])
        #expect(l1.map(\.reason) == ["attach reason", "attach reason", "attach reason"])
        #expect(l1.map(\.source) == [nil, nil, nil])
        #expect(relaunched.items(albumID: "L2").map(\.id) == ["queue-d"])
    }

    private static func rowJSON(id: String, source: String?) -> String {
        let sourceField = source.map { "\"source\": \($0)," } ?? ""
        return """
            {"id": "\(id)", "filename": "\(id).heic", "reason": "attach reason",
            "category": "userResolvable", "issue": "unknown", \(sourceField)"isPermanent": false, "isRetryable": true}
            """
    }

    @Test func anEmptyStringSourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(sourceJSON: "\"\"")
    }

    @Test func aNumberSourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(sourceJSON: "0")
    }

    @Test func anArraySourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(sourceJSON: "[]")
    }

    @Test func anObjectWithoutRequiredFieldsSourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(sourceJSON: "{\"kind\": \"photoLibraryAsset\"}")
    }

    @Test func anUnknownKindSourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(
            sourceJSON: "{\"kind\": \"weird\", \"identifier\": \"asset-a\", \"resource\": \"original\"}")
    }

    @Test func aNullSourceKeepsEveryRow() async throws {
        try await assertEveryRowSurvives(sourceJSON: "null")
    }
}
