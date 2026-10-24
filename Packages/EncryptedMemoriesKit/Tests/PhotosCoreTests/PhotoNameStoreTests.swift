import Foundation
import SQLite3
import Testing

@testable import PhotosCore

@Suite struct PhotoNameStoreTests {
    private let first = PhotoUID(volumeID: "vol", nodeID: "node-a")
    private let second = PhotoUID(volumeID: "vol", nodeID: "node-b")

    @Test func namesSurviveAReopenAndFeedTheIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_3350.HEIC", second: ""]) == .written)
        store.close()

        let reopened = try #require(makeStore(directory))
        let index = reopened.index()
        #expect(index.normalizedName(of: first) == "img_3350.heic")
        // The empty name records an unreadable name: it has a row, so it is not requested again, and never matches.
        #expect(index.normalizedName(of: second) == nil)
        #expect(reopened.recordedNodeIDs(volumeID: "vol") == ["node-a", "node-b"])
        #expect(reopened.recordedNodeIDs(volumeID: "other") == [])
    }

    @Test func theFileHoldsNoPlaintextName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "Geheimnis_Urlaub.JPG"]) == .written)
        store.close()

        let needle = Data("Geheimnis_Urlaub".utf8)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: needle) == nil, "plaintext in \(file.lastPathComponent)")
        }
    }

    /// A sealed name moved onto another photo does not open; the row is removed so the next pass reads it again.
    @Test func aSealedNameOpensOnlyForItsOwnPhoto() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG", second: "IMG_2.JPG"]) == .written)
        store.close()
        try execute(
            directory,
            "UPDATE photo_name SET sealed=(SELECT sealed FROM photo_name WHERE node='node-a') WHERE node='node-b';")

        let reopened = try #require(makeStore(directory))
        let index = reopened.index()
        #expect(index.normalizedName(of: first) == "img_1.jpg")
        #expect(index.normalizedName(of: second) == nil)
        #expect(reopened.recordedNodeIDs(volumeID: "vol") == ["node-a"])
    }

    @Test func anotherAccountKeyOpensNoName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        store.close()

        let other = try #require(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "other"))
        #expect(other.index().isEmpty)
        #expect(other.recordedNodeIDs(volumeID: "vol") == [])
    }

    @Test func forgetRemovesTheNameFromFileAndIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG", second: "IMG_2.JPG"]) == .written)
        let before = store.index()
        #expect(store.forget([first]))

        let after = store.index()
        #expect(after != before)
        #expect(after.normalizedName(of: first) == nil)
        #expect(after.normalizedName(of: second) == "img_2.jpg")
        #expect(store.recordedNodeIDs(volumeID: "vol") == ["node-b"])
    }

    @Test func aRenameReplacesTheNameInTheLoadedIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        _ = store.index()
        #expect(store.record([first: "Strand.JPG"]) == .written)
        #expect(store.index().normalizedName(of: first) == "strand.jpg")
    }

    /// A search keeps its index until it ends; afterwards the store holds no decrypted names.
    @Test func endingTheSearchDropsTheIndexAndTheNextQueryReadsTheFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        let loaded = store.index()
        #expect(store.index() == loaded)

        store.endSearch()
        let reloaded = store.index()
        #expect(reloaded != loaded)
        #expect(reloaded.normalizedName(of: first) == "img_1.jpg")
    }

    /// A write drops the kept index instead of copying it, so a backfill never copies the names of an open search.
    @Test func aWriteDropsTheKeptIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        let loaded = store.index()
        #expect(store.record([second: "IMG_2.JPG"]) == .written)
        let afterRecord = store.index()
        #expect(afterRecord != loaded)
        #expect(afterRecord.normalizedName(of: second) == "img_2.jpg")
        #expect(store.forget([first]))
        #expect(store.index() != afterRecord)
    }

    /// A name read that started before a forget may hold the old name; it writes nothing, and the photo stays without
    /// a row, so the next read fetches its new name.
    @Test func aReadOlderThanAForgetWritesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        let token = store.forgetToken
        #expect(store.forget([first]))

        #expect(store.record([first: "IMG_OLD.JPG"], unlessForgottenSince: token) == .superseded)
        #expect(store.recordedNodeIDs(volumeID: "vol") == [])
        #expect(store.record([first: "IMG_NEW.JPG"], unlessForgottenSince: store.forgetToken) == .written)
        #expect(store.index().normalizedName(of: first) == "img_new.jpg")
    }

    @Test func aClosedStoreServesNoNames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        store.close()
        #expect(store.index().isEmpty)
        #expect(store.recordedNodeIDs(volumeID: "vol") == nil)
        #expect(store.record([second: "IMG_2.JPG"]) == .failed)
    }

    /// The store sits in the account library directory, which the sign-out purge removes as a whole.
    @Test func theSignOutPurgeRemovesTheNames() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = LibraryDatabaseLocation.prepareAccountDirectory(uid: "account", in: base)
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        store.close()
        let file = directory.appendingPathComponent(PhotoNameStore.databaseFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))

        #expect(LibraryDatabaseLocation.purgeAccountData(uid: "account", in: base))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let fresh = try #require(makeStore(LibraryDatabaseLocation.prepareAccountDirectory(uid: "account", in: base)))
        #expect(fresh.index().isEmpty)
    }

    /// Shutdown closes the store before the sign-out purge: afterwards the process holds no handle to its files.
    @Test func closeLeavesNoOpenHandleToTheFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(makeStore(directory))
        #expect(store.record([first: "IMG_1.JPG"]) == .written)
        _ = store.index()
        let path = directory.resolvingSymlinksInPath().appendingPathComponent(PhotoNameStore.databaseFileName).path
        #expect(openHandles(toPathsStartingWith: path) > 0)

        store.close()

        #expect(openHandles(toPathsStartingWith: path) == 0)
        try FileManager.default.removeItem(at: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func openHandles(toPathsStartingWith prefix: String) -> Int {
        var count = 0
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(prefix) || URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(prefix) {
                count += 1
            }
        }
        return count
    }

    private func makeStore(_ directory: URL) -> PhotoNameStore? {
        PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoNameStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(_ directory: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent(PhotoNameStore.databaseFileName).path
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

@Suite struct PhotoNameStoreMemoryPressureTests {
    @MainActor @Test func aReducedMemoryBudgetDropsTheDecryptedNamesAndKeepsNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoNameStoreMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret"))
        let uid = PhotoUID(volumeID: "vol", nodeID: "node")
        #expect(store.record([uid: "IMG_1.JPG"]) == .written)
        let governor = MemoryPressureGovernor()
        let registration = governor.register(store)
        defer { registration.end() }

        let loaded = store.index()
        governor.update(MemoryConditions(pressure: .normal))
        #expect(store.index() == loaded)
        governor.update(MemoryConditions(isBackgrounded: true))
        let reduced = store.index()
        #expect(reduced != loaded)
        #expect(reduced.normalizedName(of: uid) == "img_1.jpg")
        // Below normal, each query reads the file and nothing stays kept, also after the search ends.
        #expect(store.index() != reduced)
        store.endSearch()
        #expect(store.index() != reduced)

        governor.update(MemoryConditions(pressure: .normal))
        let kept = store.index()
        #expect(store.index() == kept)
        store.endSearch()
        #expect(store.index() != kept)
    }
}

extension PhotoNameStoreMemoryPressureTests {
    @MainActor @Test(.timeLimit(.minutes(1))) func closeEndsTheMemoryRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoNameStoreMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let governor = MemoryPressureGovernor()
        let store = try #require(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret"))
        store.registerForMemoryPressure(governor)
        store.registerForMemoryPressure(governor)
        #expect(governor.responderCount == 1)

        store.close()
        while governor.responderCount != 0 { await Task.yield() }
        // A store closed first never registers.
        store.registerForMemoryPressure(governor)
        #expect(governor.responderCount == 0)
    }
}
