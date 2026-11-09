import Foundation
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter

/// Catalog files written before 1.2.0 move to the class of new writes, so a locked Smart Search window can read them
/// after the first unlock since a restart. No other Smart Search file changes its class.
@Suite(.serialized) struct CatalogFileProtectionTests {
    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("catalog-protection-\(UUID().uuidString)")
    }

    private static func write(_ files: [URL]) throws {
        for file in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
        }
    }

    private static func link(_ link: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    private static func paths(_ urls: [URL]) -> Set<String> {
        Set(urls.map { $0.resolvingSymlinksInPath().path })
    }

    /// Every file of the allowlist in a Smart Search root, beside private files that must keep their class.
    private struct Tree {
        let root: URL
        let cache: URL
        let catalogFiles: [URL]
        let privateFiles: [URL]

        init() throws {
            let root = CatalogFileProtectionTests.makeRoot()
            let cache = root.appendingPathComponent("catalog-cache", isDirectory: true)
            let pair = cache.appendingPathComponent("active-pair", isDirectory: true)
            let release = pair.appendingPathComponent("pair-1", isDirectory: true)
            let cacheNames = [
                "catalog-v1.json", "catalog-v1.sig", "catalog-v2.json", "catalog-v2.sig", "catalog-v2.accepted.json",
            ]
            let pairNames = [
                "catalog-v1.json", "catalog-v1.sig", "catalog-v2.json", "catalog-v2.sig", "release-pair.json",
            ]
            self.root = root
            self.cache = cache
            catalogFiles =
                cacheNames.map { cache.appendingPathComponent($0) } + [pair.appendingPathComponent("active-pair.json")]
                + pairNames.map { release.appendingPathComponent($0) }
                + ["catalog-v1.json", "catalog-v1.sig"].map { root.appendingPathComponent($0) }
            privateFiles = [
                root.appendingPathComponent("state.json"),
                root.appendingPathComponent("derived-index.sqlite"),
                root.appendingPathComponent("catalog-v2.json"),
                root.appendingPathComponent("models/model-a/weights.bin"),
                root.appendingPathComponent("staging/download.part"),
                cache.appendingPathComponent("unknown.json"),
                pair.appendingPathComponent(".active-pair.json.tmp"),
                release.appendingPathComponent("notes.txt"),
            ]
            try CatalogFileProtectionTests.write(catalogFiles + privateFiles)
        }
    }

    @Test func onlyTheCatalogFilesChangeAndOneFailureStopsNoOther() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        var visited: [URL] = []
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: tree.cache, legacyDirectory: tree.root
        ) { url in
            visited.append(url)
            if url.lastPathComponent == "catalog-v2.sig" { throw CocoaError(.fileWriteNoPermission) }
        }

        #expect(failures == 2, "both failed protections count")
        #expect(
            Self.paths(visited) == Self.paths(tree.catalogFiles),
            "every catalog file, and no index, state, model or other file")
    }

    @Test func aLinkedPairDirectoryIsNeverFollowed() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("private", isDirectory: true)
        let secretFiles = [
            secret.appendingPathComponent("active-pair.json"), secret.appendingPathComponent("catalog-v1.json"),
            secret.appendingPathComponent("pair-1/catalog-v1.json"),
        ]
        try Self.write(secretFiles)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        // The whole active-pair directory is a link to private data.
        try Self.link(cache.appendingPathComponent("active-pair"), to: secret)

        var visited: [URL] = []
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: cache, legacyDirectory: cache
        ) { visited.append($0) }
        #expect(visited.isEmpty, "no file behind the link changes its class")
        #expect(failures == 1, "a link where the pair directory belongs keeps the move open")

        // A real active-pair directory with one pair that is a link.
        try FileManager.default.removeItem(at: cache.appendingPathComponent("active-pair"))
        try Self.link(cache.appendingPathComponent("active-pair/pair-2"), to: secret.appendingPathComponent("pair-1"))
        visited = []
        let pairFailures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: cache, legacyDirectory: cache
        ) { visited.append($0) }
        #expect(visited.isEmpty, "no file behind a linked pair changes its class")
        #expect(pairFailures == 1)
    }

    @Test func aLinkWithACatalogNameIsNeverFollowed() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json")
        try Self.write([state])
        try Self.link(root.appendingPathComponent("catalog-v1.json"), to: state)

        var visited: [URL] = []
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: root, legacyDirectory: root
        ) { visited.append($0) }
        #expect(visited.isEmpty, "the private file behind the link keeps its class")
        #expect(failures == 1)
    }

    @Test func aLinkedCacheDirectoryIsNeverFollowed() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private")
        try Self.write([target.appendingPathComponent("catalog-v1.json")])
        let link = root.appendingPathComponent("cache")
        try Self.link(link, to: target)
        var visited: [URL] = []
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: link, legacyDirectory: root.appendingPathComponent("missing")
        ) { visited.append($0) }
        #expect(visited.isEmpty)
        #expect(failures == 1)
    }

    @Test func aLinkedLegacyDirectoryIsNeverFollowed() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private")
        try Self.write([target.appendingPathComponent("catalog-v1.json")])
        let link = root.appendingPathComponent("legacy")
        try Self.link(link, to: target)
        var visited: [URL] = []
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: root.appendingPathComponent("missing"), legacyDirectory: link
        ) { visited.append($0) }
        #expect(visited.isEmpty)
        #expect(failures == 1)
    }

    @Test func aDirectoryThatCannotBeReadIsAFailure() throws {
        let root = Self.makeRoot()
        let pair = root.appendingPathComponent("active-pair", isDirectory: true)
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pair.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: pair.path)

        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: root, legacyDirectory: root
        ) { _ in }
        #expect(failures == 1, "only the directory enumeration fails; no active-pair file exists")
    }

    @Test func aMissingTreeIsSkipped() {
        let missing = Self.makeRoot()
        var calls = 0
        let failures = SignedRemoteMLModelCatalogProvider.applyFileProtection(
            cacheDirectory: missing, legacyDirectory: missing
        ) { _ in calls += 1 }
        #expect(failures == 0)
        #expect(calls == 0)
    }

    @Test func theMoveSetsTheFirstUnlockClassAndIsDoneOnlyAfterACompleteWalk() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let state = FileProtectionUpgradeState()
        let counter = SignedRemoteMLModelCatalogProvider.fileProtectionFailureCounter
        let before = PhotoDiagnostics.shared.supportSnapshot().counters[counter] ?? 0

        var classes: [FileProtectionType] = []
        var failOnce = true
        func upgrade() {
            SignedRemoteMLModelCatalogProvider.upgradeFileProtection(
                cacheDirectory: tree.cache, legacyDirectory: tree.root, state: state
            ) { url, protection in
                classes.append(protection)
                if failOnce, url.lastPathComponent == "release-pair.json" {
                    failOnce = false
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        }

        upgrade()
        #expect(Set(classes) == [.completeUntilFirstUserAuthentication], "the class of new writes, nothing else")
        #expect(
            PhotoDiagnostics.shared.supportSnapshot().counters[counter] == before + 1,
            "a failed walk counts once in the support export")
        let firstWalk = classes.count

        upgrade()
        #expect(classes.count == 2 * firstWalk, "a walk with a failure stays open, so the next call walks again")
        #expect(
            PhotoDiagnostics.shared.supportSnapshot().counters[counter] == before + 1,
            "a successful walk adds no failure")
        upgrade()
        #expect(classes.count == 2 * firstWalk, "a complete walk is done for this process")

        // Another provider's directories are not done yet.
        let other = try Tree()
        defer { try? FileManager.default.removeItem(at: other.root) }
        var otherCalls = 0
        SignedRemoteMLModelCatalogProvider.upgradeFileProtection(
            cacheDirectory: other.cache, legacyDirectory: other.root, state: state
        ) { _, _ in otherCalls += 1 }
        #expect(otherCalls == other.catalogFiles.count, "the done record belongs to one pair of directories")
    }
}
