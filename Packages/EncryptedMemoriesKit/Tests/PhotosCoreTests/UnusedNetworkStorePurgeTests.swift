import XCTest

@testable import PhotosCore

/// Verifies the one-time removal of the unused URL cache and cookie file (#605): exactly the named
/// entries go, everything next to them stays, and only a complete run marks the purge done.
final class UnusedNetworkStorePurgeTests: XCTestCase {
    private let bundleIdentifier = "at.oncloud.encryptedmemories"
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var library: URL!
    private var caches: URL!
    private var urlCache: URL!
    private var cookies: URL!

    override func setUpWithError() throws {
        suiteName = "unused-network-store-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-network-store-\(UUID().uuidString)", isDirectory: true)
        // The macOS sandbox container layout; the purge refuses any other Library on macOS.
        library = root.appendingPathComponent("Containers/\(bundleIdentifier)/Data/Library", isDirectory: true)
        caches = library.appendingPathComponent("Caches", isDirectory: true)
        urlCache = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        cookies = library.appendingPathComponent("Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: urlCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cookies, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func seedUnusedStores() throws {
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm"] {
            try write(urlCache.appendingPathComponent(name))
        }
        try write(urlCache.appendingPathComponent("fsCachedData/0B1C2D3E"))
        try write(cookies.appendingPathComponent("Cookies.binarycookies"))
    }

    private func purge(
        bundleIdentifier: String? = nil,
        library: URL? = nil,
        caches: URL? = nil,
        requiresSandboxContainer: Bool = UnusedNetworkStorePurge.requiresSandboxContainer,
        removeItem: (URL) throws -> Void = {
            try TransientPlaintextPurge.removeWithoutFollowingLinks(at: $0, boundary: $0)
        }
    ) -> UnusedNetworkStorePurge.Result? {
        let library = library ?? self.library!
        return UnusedNetworkStorePurge.purgeOnce(
            defaults: defaults,
            libraryDirectory: library,
            cachesDirectory: caches ?? library.appendingPathComponent("Caches", isDirectory: true),
            bundleIdentifier: bundleIdentifier ?? self.bundleIdentifier,
            requiresSandboxContainer: requiresSandboxContainer,
            removeItem: removeItem
        )
    }

    private var isDone: Bool { defaults.bool(forKey: UnusedNetworkStorePurge.completedKey) }

    func testRemovesExactlyTheNamedEntriesAndKeepsEverythingNextToThem() throws {
        try seedUnusedStores()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("must-survive.txt")
        try write(outsideFile)
        try FileManager.default.createSymbolicLink(
            at: urlCache.appendingPathComponent("fsCachedData/outside-link"), withDestinationURL: outside)
        let survivors = [
            urlCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/24A434/model/compiled.bin"),
            urlCache.appendingPathComponent("Cache.db.keep"),
            urlCache.appendingPathComponent("fsCachedData-other/entry"),
            caches.appendingPathComponent("EncryptedMemories/thumbnails.enc"),
            caches.appendingPathComponent("other.bundle/Cache.db"),
            library.appendingPathComponent("Application Support/EncryptedMemories/library.sqlite"),
            library.appendingPathComponent("Application Support/Cache.db"),
            library.appendingPathComponent("Cookies.binarycookies"),
            cookies.appendingPathComponent("Other.binarycookies"),
        ]
        for survivor in survivors {
            try write(survivor)
        }

        let result = try XCTUnwrap(purge())

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            Set(result.removed.map(\.lastPathComponent)),
            ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData", "Cookies.binarycookies"])
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"] {
            XCTAssertFalse(exists(urlCache.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
        for survivor in survivors {
            XCTAssertTrue(exists(survivor), survivor.path)
        }
        XCTAssertTrue(exists(urlCache), "the container itself stays")
        XCTAssertTrue(exists(cookies), "the cookie folder itself stays")
        XCTAssertTrue(exists(outsideFile), "a link inside fsCachedData is not followed")
        XCTAssertTrue(isDone)
    }

    func testRunsOnlyOnce() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())
        XCTAssertTrue(isDone)

        try seedUnusedStores()
        XCTAssertNil(purge(), "a completed purge does not run again")
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
    }

    func testSignOutPurgesTheNamedStoresAfterACompletedStartupAndKeepsOtherEntries() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())
        XCTAssertTrue(isDone)
        try seedUnusedStores()
        let protected = [
            urlCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/compiled.bin"),
            urlCache.appendingPathComponent("Cache.db.keep"),
            caches.appendingPathComponent("EncryptedMemories/protected.cache"),
            cookies.appendingPathComponent("Other.binarycookies"),
        ]
        for file in protected { try write(file) }
        let result = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeForSignOut(
                defaults: defaults,
                location: UnusedNetworkStorePurge.Location(
                    libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed.count, 5)
        for file in protected { XCTAssertTrue(exists(file)) }
    }

    func testSignOutRefusesLinkedContainersWithoutFollowingOrDeletingThem() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("Cache.db")
        try write(outsideCache)
        try FileManager.default.removeItem(at: urlCache)
        try FileManager.default.createSymbolicLink(at: urlCache, withDestinationURL: outside)
        let result = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeForSignOut(
                defaults: defaults,
                location: UnusedNetworkStorePurge.Location(
                    libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(exists(outsideCache))
        XCTAssertTrue(exists(urlCache))
        XCTAssertFalse(isDone)
    }

    func testSignOutRefusesAStaticLibraryAncestorLink() throws {
        try assertStaticAncestorLinkIsRefused(at: library)
    }

    func testSignOutRefusesAStaticCachesAncestorLink() throws {
        try assertStaticAncestorLinkIsRefused(at: caches)
    }

    func testSignOutRefusesAStaticDataAncestorLink() throws {
        try assertStaticAncestorLinkIsRefused(at: library.deletingLastPathComponent())
    }

    func testSignOutRefusesAStaticTrustedBoundaryLink() throws {
        let boundary =
            UnusedNetworkStorePurge.requiresSandboxContainer
            ? library.deletingLastPathComponent().deletingLastPathComponent()
            : library.deletingLastPathComponent()
        try assertStaticAncestorLinkIsRefused(at: boundary)
    }

    private func assertStaticAncestorLinkIsRefused(at ancestor: URL) throws {
        try seedUnusedStores()
        let destination = root.appendingPathComponent("linked-destination", isDirectory: true)
        let protected = urlCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/compiled.bin")
        try write(protected)
        try FileManager.default.moveItem(at: ancestor, to: destination)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: destination)
        let cacheDestination = destination.appendingPathComponent(
            String(urlCache.path.dropFirst(ancestor.path.count + 1)))
        let result = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeForSignOut(
                defaults: defaults,
                location: UnusedNetworkStorePurge.Location(
                    libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)))
        XCTAssertFalse(result.succeeded, "a static ancestor link must refuse deletion")
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/0B1C2D3E"] {
            XCTAssertTrue(
                exists(cacheDestination.appendingPathComponent(name)), "linked destination must survive: \(name)")
        }
        XCTAssertTrue(exists(cacheDestination.appendingPathComponent("com.apple.e5rt.e5bundlecache/compiled.bin")))
        if ancestor != caches {
            let cookieDestination = destination.appendingPathComponent(
                String(cookies.path.dropFirst(ancestor.path.count + 1)))
            XCTAssertTrue(exists(cookieDestination.appendingPathComponent("Cookies.binarycookies")))
        } else {
            XCTAssertFalse(
                exists(cookies.appendingPathComponent("Cookies.binarycookies")), "safe independent container runs")
        }
        XCTAssertFalse(isDone)
    }

    func testAnAliasAboveTheTrustedAppContainerDoesNotRefuseCleanup() throws {
        try seedUnusedStores()
        let aliasParent = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        let alias = aliasParent.appendingPathComponent("Containers", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: root.appendingPathComponent("Containers", isDirectory: true))
        let aliasLibrary = alias.appendingPathComponent("\(bundleIdentifier)/Data/Library", isDirectory: true)
        let result = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeForSignOut(
                defaults: defaults,
                location: UnusedNetworkStorePurge.Location(
                    libraryDirectory: aliasLibrary,
                    cachesDirectory: aliasLibrary.appendingPathComponent("Caches", isDirectory: true),
                    bundleIdentifier: bundleIdentifier)))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed.count, 5)
        XCTAssertTrue(isDone)
    }

    func testIOSBoundaryRuleRefusesALinkAtTheLibraryParent() throws {
        try seedUnusedStores()
        let data = library.deletingLastPathComponent()
        let destination = root.appendingPathComponent("ios-boundary-destination", isDirectory: true)
        try FileManager.default.moveItem(at: data, to: destination)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: destination)
        let result = try XCTUnwrap(purge(requiresSandboxContainer: false))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(isDone)
        XCTAssertTrue(exists(destination.appendingPathComponent("Library/Caches/\(bundleIdentifier)/Cache.db")))
        XCTAssertTrue(exists(destination.appendingPathComponent("Library/Cookies/Cookies.binarycookies")))
    }

    func testUnreadableTrustedBoundaryCannotEstablishAbsence() throws {
        try seedUnusedStores()
        let boundary =
            UnusedNetworkStorePurge.requiresSandboxContainer
            ? library.deletingLastPathComponent().deletingLastPathComponent()
            : library.deletingLastPathComponent()
        let parent = boundary.deletingLastPathComponent()
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: parent.path)
            } catch {
                XCTFail("Could not restore the owned boundary permission fixture")
            }
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: boundary.path)
            XCTFail("Boundary permission fixture did not cause the required metadata error")
            return
        } catch {
            guard let error = error as? CocoaError, error.code == .fileReadNoPermission else {
                XCTFail("Boundary permission fixture caused an unexpected error category")
                return
            }
            print("605 boundary metadata probe: verified non-missing CocoaError.fileReadNoPermission")
        }
        let result = try XCTUnwrap(purge())
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: parent.path)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertFalse(isDone)
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
    }

    func testMissingEntriesAndContainersAreNotAnError() throws {
        let result = try XCTUnwrap(purge())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(isDone)

        defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
        try FileManager.default.removeItem(at: urlCache)
        try FileManager.default.removeItem(at: cookies)
        let withoutContainers = try XCTUnwrap(purge())
        XCTAssertTrue(withoutContainers.succeeded)
        XCTAssertTrue(isDone)
    }

    func testMissingTrustedBoundaryEstablishesAbsence() throws {
        let boundary =
            UnusedNetworkStorePurge.requiresSandboxContainer
            ? library.deletingLastPathComponent().deletingLastPathComponent()
            : library.deletingLastPathComponent()
        try FileManager.default.removeItem(at: boundary)
        let result = try XCTUnwrap(purge())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(isDone)
    }

    func testOneFailedRemovalDoesNotStopTheOthersAndKeepsThePurgePending() throws {
        try seedUnusedStores()
        let wal = urlCache.appendingPathComponent("Cache.db-wal").standardizedFileURL

        let failed = try XCTUnwrap(
            purge(removeItem: { url in
                if url.lastPathComponent == "Cache.db-wal" { throw CocoaError(.fileWriteNoPermission) }
                try TransientPlaintextPurge.removeWithoutFollowingLinks(at: url, boundary: url)
            }))

        XCTAssertEqual(failed.failed, [wal])
        XCTAssertEqual(failed.removed.count, 4)
        XCTAssertTrue(exists(wal))
        XCTAssertFalse(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertFalse(exists(urlCache.appendingPathComponent("fsCachedData")))
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
        XCTAssertFalse(isDone, "a failed removal must be retried at the next launch")

        let retry = try XCTUnwrap(purge())
        XCTAssertEqual(retry.removed, [wal])
        XCTAssertFalse(exists(wal))
        XCTAssertTrue(isDone)
    }

    func testUnreadableNamedEntriesCannotCompleteThePurge() throws {
        try seedUnusedStores()
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: urlCache.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urlCache.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: urlCache.path)
            } catch {
                XCTFail("Could not restore the owned permission fixture")
            }
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: urlCache.appendingPathComponent("Cache.db").path)
            XCTFail("Permission fixture did not cause the required metadata error")
            return
        } catch {
            guard let error = error as? CocoaError, error.code == .fileReadNoPermission else {
                XCTFail("Permission fixture caused an unexpected error category")
                return
            }
            print("605 metadata probe: verified non-missing CocoaError.fileReadNoPermission")
        }

        let result = try XCTUnwrap(purge())
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: urlCache.path)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(isDone)
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
    }

    func testUnreadableContainerCannotCompleteThePurge() throws {
        try seedUnusedStores()
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: caches.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: caches.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: caches.path)
            } catch {
                XCTFail("Could not restore the owned container permission fixture")
            }
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: urlCache.path)
            XCTFail("Container permission fixture did not cause the required metadata error")
            return
        } catch {
            guard let error = error as? CocoaError, error.code == .fileReadNoPermission else {
                XCTFail("Container permission fixture caused an unexpected error category")
                return
            }
            print("605 container metadata probe: verified non-missing CocoaError.fileReadNoPermission")
        }

        let result = try XCTUnwrap(purge())
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: caches.path)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failed, [urlCache.standardizedFileURL])
        XCTAssertFalse(isDone)
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
    }

    func testFailedSignOutClearsAnEarlierStartupCompletionAndCanRetry() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())
        XCTAssertTrue(isDone)
        try seedUnusedStores()
        let result = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeOnce(
                defaults: defaults, libraryDirectory: library, cachesDirectory: caches,
                bundleIdentifier: bundleIdentifier, honorCompletedFlag: false,
                removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failed.count, 5)
        XCTAssertEqual(result.removed, [])
        XCTAssertFalse(isDone)
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))

        let retry = try XCTUnwrap(
            UnusedNetworkStorePurge.purgeForSignOut(
                defaults: defaults,
                location: UnusedNetworkStorePurge.Location(
                    libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)))
        XCTAssertTrue(retry.succeeded)
        XCTAssertEqual(retry.removed.count, 5)
        XCTAssertTrue(isDone)
    }

    func testAnEntryThatVanishesDuringRemovalCountsAsRemoved() throws {
        try seedUnusedStores()

        let result = try XCTUnwrap(
            purge(removeItem: { url in
                try TransientPlaintextPurge.removeWithoutFollowingLinks(at: url, boundary: url)
                throw CocoaError(.fileNoSuchFile)
            }))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed.count, 5)
        XCTAssertTrue(isDone)
    }

    func testCachesOutsideTheAppLibraryAreRefused() throws {
        let foreignCaches = root.appendingPathComponent("elsewhere/Caches", isDirectory: true)
        let foreignCache = foreignCaches.appendingPathComponent("\(bundleIdentifier)/Cache.db")
        try write(foreignCache)
        try write(cookies.appendingPathComponent("Cookies.binarycookies"))

        XCTAssertNil(purge(caches: foreignCaches))

        XCTAssertTrue(exists(foreignCache))
        XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
        XCTAssertFalse(isDone)
    }

    func testANamedEntryThatIsALinkIsRemovedAsALink() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideDatabase = outside.appendingPathComponent("database")
        let outsideFolder = outside.appendingPathComponent("folder", isDirectory: true)
        let outsideFolderFile = outsideFolder.appendingPathComponent("entry")
        try write(outsideDatabase)
        try write(outsideFolderFile)
        try FileManager.default.createSymbolicLink(
            at: urlCache.appendingPathComponent("Cache.db"), withDestinationURL: outsideDatabase)
        try FileManager.default.createSymbolicLink(
            at: urlCache.appendingPathComponent("fsCachedData"), withDestinationURL: outsideFolder)

        let result = try XCTUnwrap(purge())

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertFalse(exists(urlCache.appendingPathComponent("fsCachedData")))
        XCTAssertTrue(exists(outsideDatabase))
        XCTAssertTrue(exists(outsideFolderFile))
    }

    /// Uses the iOS rule (no sandbox layout check), so only the containment check can refuse the identifier.
    func testBundleIdentifierCannotLeaveTheCachesDirectory() throws {
        let escaped = library.appendingPathComponent("escape/Cache.db")
        try write(escaped)

        let result = try XCTUnwrap(purge(bundleIdentifier: "../escape", requiresSandboxContainer: false))

        XCTAssertTrue(exists(escaped))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(isDone)
    }

    func testLinkedContainersAreNotFollowed() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("Cache.db")
        let outsideCookies = outside.appendingPathComponent("Cookies.binarycookies")
        try write(outsideCache)
        try write(outsideCookies)
        try FileManager.default.removeItem(at: urlCache)
        try FileManager.default.removeItem(at: cookies)
        try FileManager.default.createSymbolicLink(at: urlCache, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: cookies, withDestinationURL: outside)

        let result = try XCTUnwrap(purge())

        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(exists(outsideCache))
        XCTAssertTrue(exists(outsideCookies))
    }

    func testDoesNothingInsideAnotherAppsSandboxContainer() throws {
        let otherLibrary = root.appendingPathComponent("Containers/other.id/Data/Library", isDirectory: true)
        let otherCache = otherLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
        let otherCookies = otherLibrary.appendingPathComponent("Cookies/Cookies.binarycookies")
        try write(otherCache)
        try write(otherCookies)

        XCTAssertNil(purge(library: otherLibrary, requiresSandboxContainer: true))

        XCTAssertTrue(exists(otherCache))
        XCTAssertTrue(exists(otherCookies))
        XCTAssertFalse(isDone)
    }

    #if os(macOS)
        /// An unsandboxed run shares `Library/Cookies` with other apps. It removes nothing and still completes (#792).
        func testOutsideAMacSandboxContainerRemovesNothingAndCompletes() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let sharedCookies = sharedLibrary.appendingPathComponent("Cookies/Cookies.binarycookies")
            let sharedCache = sharedLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(sharedCookies)
            try write(sharedCache)

            let result = try XCTUnwrap(purge(library: sharedLibrary))

            XCTAssertEqual(result.removed, [])
            XCTAssertEqual(result.failed, [])
            XCTAssertTrue(exists(sharedCookies))
            XCTAssertTrue(exists(sharedCache))
            XCTAssertTrue(isDone)
        }

        private func linkedLibrary(to destination: URL) throws -> URL {
            let link = root.appendingPathComponent("Users/\(UUID().uuidString)/Library", isDirectory: true)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            return link
        }

        /// A Library that leads into a container through a link is not an unsandboxed Library.
        func testALibraryLinkIntoTheOwnContainerIsRefused() throws {
            try seedUnusedStores()

            XCTAssertNil(purge(library: try linkedLibrary(to: library)))

            XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
            XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
            XCTAssertFalse(isDone)
        }

        func testALibraryLinkIntoAnotherAppsContainerIsRefused() throws {
            let otherLibrary = root.appendingPathComponent("Containers/other.id/Data/Library", isDirectory: true)
            let otherCache = otherLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(otherCache)

            XCTAssertNil(purge(library: try linkedLibrary(to: otherLibrary)))

            XCTAssertTrue(exists(otherCache))
            XCTAssertFalse(isDone)
        }

        /// A case-insensitive volume stores `containers` and `data` in any case.
        func testALowercaseContainerLayoutIsRefused() throws {
            let otherLibrary = root.appendingPathComponent("lower/containers/other.id/data/Library", isDirectory: true)
            let otherCache = otherLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(otherCache)

            XCTAssertNil(purge(library: otherLibrary))
            defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
            XCTAssertNil(purge(library: try linkedLibrary(to: otherLibrary)))

            XCTAssertTrue(exists(otherCache))
            XCTAssertFalse(isDone)
        }

        func testAGroupContainerLibraryIsRefused() throws {
            let groupLibrary = root.appendingPathComponent("Group Containers/group.other/Library", isDirectory: true)
            let groupCache = groupLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(groupCache)

            XCTAssertNil(purge(library: groupLibrary))
            defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
            XCTAssertNil(purge(library: try linkedLibrary(to: groupLibrary)))

            XCTAssertTrue(exists(groupCache))
            XCTAssertFalse(isDone)
        }

        /// A link to another plain Library is still outside every container. It completes and removes nothing.
        func testALibraryLinkToAnotherPlainLibraryCompletesWithoutRemovingAnything() throws {
            let plainLibrary = root.appendingPathComponent("Users/other/Library", isDirectory: true)
            let plainCache = plainLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            let plainCookies = plainLibrary.appendingPathComponent("Cookies/Cookies.binarycookies")
            try write(plainCache)
            try write(plainCookies)

            let result = try XCTUnwrap(purge(library: try linkedLibrary(to: plainLibrary)))

            XCTAssertEqual(result.removed, [])
            XCTAssertEqual(result.failed, [])
            XCTAssertTrue(exists(plainCache))
            XCTAssertTrue(exists(plainCookies))
            XCTAssertTrue(isDone)
        }

        func testALibraryThatIsAFileIsRefused() throws {
            let fileLibrary = root.appendingPathComponent("Users/someone/Library")
            try write(fileLibrary)

            XCTAssertNil(purge(library: fileLibrary))

            XCTAssertFalse(isDone)
        }

        func testUnsandboxedCachesThatLinkToAForeignFolderAreRefused() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedLibrary, withIntermediateDirectories: true)
            let foreignCaches = root.appendingPathComponent("foreign/Caches", isDirectory: true)
            let foreignCache = foreignCaches.appendingPathComponent("\(bundleIdentifier)/Cache.db")
            try write(foreignCache)
            try FileManager.default.createSymbolicLink(
                at: sharedLibrary.appendingPathComponent("Caches"), withDestinationURL: foreignCaches)

            XCTAssertNil(purge(library: sharedLibrary))

            XCTAssertTrue(exists(foreignCache))
            XCTAssertFalse(isDone)
        }

        /// A Caches path that ends in `.` or `child/..` still names the literal Caches entry; a link there is refused.
        func testUnsandboxedCachesWithDotComponentsCannotHideALink() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let realCaches = sharedLibrary.appendingPathComponent("RealCaches", isDirectory: true)
            try write(realCaches.appendingPathComponent("child/entry"))
            let foreignCaches = root.appendingPathComponent("foreign/Caches", isDirectory: true)
            try write(foreignCaches.appendingPathComponent("child/entry"))
            let caches = sharedLibrary.appendingPathComponent("Caches")
            for destination in [realCaches, foreignCaches] {
                try? FileManager.default.removeItem(at: caches)
                try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: destination)
                for suffix in ["/.", "/child/.."] {
                    defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
                    let dotted = URL(fileURLWithPath: caches.path + suffix)

                    XCTAssertNil(purge(library: sharedLibrary, caches: dotted), destination.lastPathComponent + suffix)
                    XCTAssertFalse(isDone, destination.lastPathComponent + suffix)
                }
            }
        }

        func testUnsandboxedCachesWithDotComponentsOnARealFolderComplete() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let caches = sharedLibrary.appendingPathComponent("Caches", isDirectory: true)
            try write(caches.appendingPathComponent("child/entry"))
            for suffix in ["/.", "/child/.."] {
                defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)

                let result = purge(library: sharedLibrary, caches: URL(fileURLWithPath: caches.path + suffix))

                XCTAssertEqual(result, UnusedNetworkStorePurge.Result(removed: [], failed: []), suffix)
                XCTAssertTrue(isDone, suffix)
            }
        }

        /// The written path is the lexically standardized path: components that `..` cancels do not count.
        func testCancelledContainerComponentsInTheWrittenPathDoNotRefuse() throws {
            let plainLibrary = root.appendingPathComponent("Plain/Library", isDirectory: true)
            try write(plainLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db"))
            for folder in ["Containers/x/Data", "Group Containers"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
            }
            for written in ["Containers/x/Data/../../../Plain/Library", "Group Containers/../Plain/Library"] {
                defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
                let library = URL(fileURLWithPath: root.path + "/" + written)

                let result = purge(library: library, caches: URL(fileURLWithPath: library.path + "/Caches"))

                XCTAssertEqual(result, UnusedNetworkStorePurge.Result(removed: [], failed: []), written)
            }
            XCTAssertTrue(exists(plainLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")))
        }

        func testUnsandboxedCachesThatLinkInsideTheLibraryAreRefused() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let realCaches = sharedLibrary.appendingPathComponent("RealCaches", isDirectory: true)
            try write(realCaches.appendingPathComponent("\(bundleIdentifier)/Cache.db"))
            try FileManager.default.createSymbolicLink(
                at: sharedLibrary.appendingPathComponent("Caches"), withDestinationURL: realCaches)

            XCTAssertNil(purge(library: sharedLibrary))

            XCTAssertFalse(isDone)
        }

        func testAnAncestorLinkIntoAContainerIsRefused() throws {
            try seedUnusedStores()
            let data = library.deletingLastPathComponent()
            let link = root.appendingPathComponent("Users/someone", isDirectory: true)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)

            XCTAssertNil(purge(library: link.appendingPathComponent("Library", isDirectory: true)))

            XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
            XCTAssertFalse(isDone)
        }

        /// The written path counts as well: a container path that links to a plain Library is still refused.
        func testAContainerPathLinkedToAPlainLibraryIsRefused() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let sharedCache = sharedLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(sharedCache)
            let otherLibrary = root.appendingPathComponent("Containers/other.id/Data/Library", isDirectory: true)
            try FileManager.default.createDirectory(
                at: otherLibrary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: otherLibrary, withDestinationURL: sharedLibrary)

            XCTAssertNil(purge(library: otherLibrary))

            XCTAssertTrue(exists(sharedCache))
            XCTAssertFalse(isDone)
        }

        func testAMissingLibraryOutsideAContainerIsRefused() throws {
            XCTAssertNil(purge(library: root.appendingPathComponent("Users/nobody/Library", isDirectory: true)))
            XCTAssertFalse(isDone)
        }

        func testCachesOutsideAnUnsandboxedLibraryAreRefused() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedLibrary, withIntermediateDirectories: true)
            let foreignCaches = root.appendingPathComponent("elsewhere/Caches", isDirectory: true)
            let foreignCache = foreignCaches.appendingPathComponent("\(bundleIdentifier)/Cache.db")
            try write(foreignCache)

            XCTAssertNil(purge(library: sharedLibrary, caches: foreignCaches))

            XCTAssertTrue(exists(foreignCache))
            XCTAssertFalse(isDone)
        }
    #endif

    /// iOS has no container layout rule. Its Library keeps the full removal of the five names.
    func testIOSRuleRemovesTheNamedEntriesOutsideAContainerLayout() throws {
        let iOSLibrary = root.appendingPathComponent("\(UUID().uuidString)/Library", isDirectory: true)
        let iOSCache = iOSLibrary.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true)
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/0B1C2D3E"] {
            try write(iOSCache.appendingPathComponent(name))
        }
        try write(iOSLibrary.appendingPathComponent("Cookies/Cookies.binarycookies"))

        let result = try XCTUnwrap(purge(library: iOSLibrary, requiresSandboxContainer: false))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            Set(result.removed.map(\.lastPathComponent)),
            ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData", "Cookies.binarycookies"])
        XCTAssertTrue(isDone)
    }

    /// Sign-out clears the app's preferences, so the next cold launch removes any URL cache or
    /// cookie file that appeared since the last purge.
    func testSignOutArmsThePurgeForTheNextLaunch() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())

        try seedUnusedStores()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults, persistentDomainName: suiteName)
        let afterSignOut = try XCTUnwrap(purge())

        XCTAssertEqual(afterSignOut.removed.count, 5)
        XCTAssertFalse(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
    }
}
