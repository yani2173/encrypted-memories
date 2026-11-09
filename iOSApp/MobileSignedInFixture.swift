import AlbumCore
import AlbumSyncCore
import Foundation
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import TimelineCore
import UIKit
import UploadCore
import os

#if DEBUG
    /// A deterministic, offline account for hosted tests and UI tests. Debug builds only.
    ///
    /// It replaces only the account backend and its content inside the process-wide `MobileAccountRuntime`. Every
    /// production layer above it (scene roots, tab shell, timeline screens, grids, selection, search, viewer) renders
    /// unchanged. No real account, keychain entry, network request, or physical device is involved.
    @MainActor final class MobileSignedInFixture {
        static let sectionNames = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
        nonisolated static let videoNodeID = "zeta-video"
        /// The one original that every fixture photo offers as the original of its edit.
        nonisolated static let editedOriginalUID = PhotoUID(volumeID: "fixture", nodeID: "edited-original")

        let session = ProtonSession(
            uid: "fixture-account", accessToken: "fixture-access", refreshToken: "fixture-refresh",
            keyPassword: "fixture-key")
        let sections: [TimelineSection]
        let backend: MobileFixtureBackend
        let cache: ThumbnailCache
        let feed: UIKitThumbnailFeed
        var items: [PhotoItem] { sections.flatMap(\.items) }

        private let runtime: MobileAccountRuntime
        private let cacheDirectory: URL
        private var backupFixture: PhotoLibraryBackupController?
        private var albumSyncFixture: AlbumSyncController?

        /// `includesVideo` adds one video as the newest item; the UI tests use it, the hosted tests count photos only.
        init(
            runtime: MobileAccountRuntime = .shared, itemsPerSection: Int = 36, includesVideo: Bool = false
        ) async throws {
            guard !BackupLocalDataPurge.isPurgePending() else { throw MobileFixtureError.pendingAccountPurge }
            self.runtime = runtime
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "signed-in-fixture-" + UUID().uuidString)
            var sections: [TimelineSection] = []
            var thumbnails: [PhotoUID: Data] = [:]
            let calendar = Calendar(identifier: .gregorian)
            for (sectionIndex, name) in Self.sectionNames.enumerated() {
                let sectionDate = calendar.date(from: DateComponents(year: 2026, month: sectionIndex + 1, day: 12))!
                var items: [PhotoItem] = []
                for index in 0..<itemsPerSection {
                    let uid = PhotoUID(volumeID: "fixture", nodeID: "\(name)-\(index)")
                    let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                        UIColor(
                            hue: CGFloat(sectionIndex) / CGFloat(Self.sectionNames.count), saturation: 0.55,
                            brightness: 0.45 + 0.5 * CGFloat(index % 6) / 6, alpha: 1
                        ).setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
                    }
                    guard let data = bitmap.jpegData(compressionQuality: 0.8) else { throw MobileFixtureError.bitmap }
                    thumbnails[uid] = data
                    items.append(
                        PhotoItem(
                            uid: uid, captureTime: sectionDate.addingTimeInterval(TimeInterval(index) * 60),
                            mediaType: "image/jpeg"))
                }
                if includesVideo, sectionIndex == Self.sectionNames.count - 1 {
                    // The newest item is one video whose stream is unavailable, like a video that an offline
                    // account cannot play.
                    let uid = PhotoUID(volumeID: "fixture", nodeID: Self.videoNodeID)
                    thumbnails[uid] = thumbnails[items[0].uid]
                    items.append(
                        PhotoItem(
                            uid: uid, captureTime: sectionDate.addingTimeInterval(TimeInterval(itemsPerSection) * 60),
                            mediaType: "video/quicktime", durationSeconds: 3))
                }
                sections.append(
                    TimelineSection(id: "fixture-\(name)", date: sectionDate, title: "Fixture \(name)", items: items))
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesOnThisDayFixture") {
                // Two photos from today one year ago and one from two years ago, in the device's calendar like the
                // library itself, so On This Day has two stacks.
                let today = Calendar.current.startOfDay(for: Date())
                var memories: [PhotoItem] = []
                for (index, yearsAgo) in [1, 1, 2].enumerated() {
                    guard let day = Calendar.current.date(byAdding: .year, value: -yearsAgo, to: today) else {
                        continue
                    }
                    let uid = PhotoUID(volumeID: "fixture", nodeID: "memory-\(index)")
                    thumbnails[uid] = thumbnails[sections[0].items[index].uid]
                    memories.append(
                        PhotoItem(
                            uid: uid, captureTime: day.addingTimeInterval(TimeInterval(12 * 3_600 + index * 60)),
                            mediaType: "image/jpeg"))
                }
                sections.insert(
                    TimelineSection(
                        id: "fixture-memories", date: memories[0].captureTime, title: "Fixture memories",
                        items: memories),
                    at: 0)
            }
            let original = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            }
            thumbnails[Self.editedOriginalUID] = original.jpegData(compressionQuality: 0.8)
            self.sections = sections
            backend = MobileFixtureBackend(sections: sections, thumbnails: thumbnails)
            cache = ThumbnailCache(rootDirectory: cacheDirectory)
            feed = UIKitThumbnailFeed(cache: cache, loader: backend)
            for (uid, data) in thumbnails {
                await cache.store(data, for: uid)
            }
            _ = await feed.warmDecoded(thumbnails.keys.map { $0 })
        }

        /// Signs the shared account runtime in with this fixture. Library content first, then the session, so the
        /// runtime's session observer finds an already configured account and does not start a network backend.
        func install() {
            let albums = MobileFixtureAlbums(
                startsEmpty: ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesEmptyAlbumFixture"))
            runtime.libraryModel.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend,
                sections: MobileUITestLaunch.libraryLoadScenario == nil ? sections : [],
                thumbnailFeed: feed,
                albums: AlbumsRepository(
                    catalogBackend: albums, writeBackend: albums, capabilities: MobileFixtureAlbums.capabilities))
            runtime.libraryModel.settleIsolatedLibraryForTesting()
            if let scenario = MobileUITestLaunch.libraryLoadScenario {
                installLibraryLoadScenario(scenario)
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDeletedBackupFixture") {
                installDeletedBackupFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesFailedBackupFixture") {
                installDeletedBackupFixture(failedItems: true)
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesPausedBackupFixture") {
                installPausedBackupFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesBackupQueueFixture") {
                installDeletedBackupFixture(queue: true)
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesAlbumSyncReasonsFixture") {
                installAlbumSyncReasonsFixture()
            }
            if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDuplicatesFixture") {
                let items = sections.prefix(2).flatMap { $0.items.prefix(2) }
                runtime.libraryModel.installIsolatedDuplicatesForTesting(
                    MobileFixtureDuplicates(
                        groups: sections.prefix(2).map { $0.items.prefix(2).map(\.uid) },
                        captureDates: Dictionary(
                            items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first }),
                        rescanDropsLastGroup: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesRescanDropsGroup"),
                        scanDelay: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesSlowScan") ? .seconds(5) : nil,
                        invalidatingMergeReloadFails: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesReloadFailure"),
                        mergeFailure: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesPermanentMergeFailure")
                            ? .userAuthenticationRequired
                            : ProcessInfo.processInfo.arguments.contains(
                                "-EncryptedMemoriesDuplicatesMergeFailure") ? .timedOut : nil))
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDuplicatesWideFixture") {
                // One group with more copies than fit on the screen, and one whose two copies fit.
                let wide = Array(sections[0].items.prefix(12))
                let fitting = Array(sections[1].items.prefix(2))
                runtime.libraryModel.installIsolatedDuplicatesForTesting(
                    MobileFixtureDuplicates(
                        groups: [wide.map(\.uid), fitting.map(\.uid)],
                        captureDates: Dictionary(
                            (wide + fitting).map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first }))
                )
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDuplicatesLargeFixture") {
                // 1,500 groups of two or three library photos, for the scrolling and memory measurement.
                let items = sections.flatMap(\.items)
                let groups = (0..<1_500).map { index in
                    (0..<(index.isMultiple(of: 3) ? 3 : 2)).map { items[(index * 3 + $0) % items.count].uid }
                }
                // A held scan or check keeps its screen for 300 s, longer than any test (the longest takes about
                // 31 s). No test waits for the end of the hold, so a slow runner cannot lose the screen.
                let hold = Duration.seconds(300)
                runtime.libraryModel.installIsolatedDuplicatesForTesting(
                    MobileFixtureDuplicates(
                        groups: groups,
                        captureDates: Dictionary(
                            items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first }),
                        scanDelay: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesSlowScan") ? hold : nil,
                        rankDelay: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesSlowCheck") ? hold : nil,
                        // Each batch of Merge All takes a while, so a UI test can stop it.
                        mergeDelay: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesSlowMerge") ? .milliseconds(500) : nil))
            } else if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesDuplicatesCheckingFixture") {
                runtime.libraryModel.installIsolatedDuplicatesForTesting(
                    MobileFixtureDuplicates(
                        groups: [], checking: true,
                        buildInterruptions: ProcessInfo.processInfo.arguments.contains(
                            "-EncryptedMemoriesDuplicatesInterruptedCheck") ? 2 : 0))
            }
            runtime.sessionModel.installIsolatedSession(session)
        }

        private func installLibraryLoadScenario(_ scenario: String) {
            let model = runtime.libraryModel
            switch scenario {
            case "pending", "later", "offline":
                model.applyIsolatedLibraryLoadEventsForTesting([])
                if scenario == "offline" {
                    LibraryRuntimeState.shared.update { $0.network = LibraryNetworkState(isReachable: false) }
                } else if scenario == "later" {
                    model.installIsolatedInitialLoadForTesting { [self] in
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        model.installIsolatedLibrary(
                            session: session, store: runtime.sessionModel.sessionStore,
                            backend: backend, sections: sections, thumbnailFeed: feed
                        )
                        model.settleIsolatedLibraryForTesting()
                    }
                }
            case "failed", "cached-empty-failed":
                let events: [LibraryLoadEvent] =
                    scenario == "cached-empty-failed"
                    ? [
                        .inventoryResolved(count: 0, cached: true),
                        .failed(message: "Fixture first load failed", retryable: true),
                    ]
                    : [.failed(message: "Fixture first load failed", retryable: true)]
                model.applyIsolatedLibraryLoadEventsForTesting(events)
            case "empty", "backup-on":
                installEmptyBackupFixture(enabled: scenario == "backup-on")
            case "unavailable":
                break
            default:
                assertionFailure("Unknown library load fixture")
            }
        }

        private func installEmptyBackupFixture(enabled: Bool) {
            let directory = cacheDirectory.appendingPathComponent("empty-backup", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let suite = "empty-backup-fixture"
                guard let defaults = UserDefaults(suiteName: suite),
                    let journal = EditReplacementJournalFileStore.shared(accountDataDirectory: directory)
                else { throw MobileFixtureError.bitmap }
                defaults.removePersistentDomain(forName: suite)
                let controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    replacementJournal: journal
                )
                if enabled {
                    guard controller.installFailedItemsFixtureForTesting(kinds: []) else {
                        throw MobileFixtureError.bitmap
                    }
                }
                backupFixture = controller
                runtime.libraryModel.installIsolatedBackupForTesting(controller)
            } catch {
                assertionFailure("The empty backup fixture could not be installed")
            }
        }

        static let albumSyncFixtureAlbumID = "fixture-album-sync"

        /// One synced album whose last run left two photos outside the Proton album.
        private func installAlbumSyncReasonsFixture() {
            let directory = cacheDirectory.appendingPathComponent("albumsync", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let controller = AlbumSyncController(
                    configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    remoteOps: MobileFixtureAlbumSyncRemoteOps())
                guard
                    controller.installNotInAlbumFixtureForTesting(
                        albumID: Self.albumSyncFixtureAlbumID, title: "Fixture Album Sync")
                else { return }
                albumSyncFixture = controller
                runtime.libraryModel.installIsolatedAlbumSyncForTesting(controller)
            } catch {
                assertionFailure("The album sync fixture could not be installed")
            }
        }

        /// A visible local preview without reading the person's Photos library in UI tests.
        static func backupProblemThumbnail(for uid: PhotoUID) -> CGImage? {
            guard !ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesMissingProblemPreview"),
                uid.localPendingNamespace == .photoLibrary, uid.nodeID.hasPrefix("fixture-")
            else { return nil }
            return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
                UIColor.magenta.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            }.cgImage
        }

        private func installDeletedBackupFixture(failedItems: Bool = false, queue: Bool = false) {
            let directory = cacheDirectory.appendingPathComponent("backup", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let journal = EditReplacementJournalFileStore.shared(accountDataDirectory: directory),
                    let defaults = UserDefaults(suiteName: "deleted-backup-fixture")
                else { return }
                defaults.removePersistentDomain(forName: "deleted-backup-fixture")
                let controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    replacementJournal: journal)
                let installed: Bool
                if queue {
                    installed = controller.installQueueFixtureForTesting()
                } else if failedItems {
                    let arguments = ProcessInfo.processInfo.arguments
                    let kinds: [BackupIssueKind]
                    if arguments.contains("-EncryptedMemoriesNetworkOnlyBackupFixture") {
                        kinds = [.network]
                    } else if arguments.contains("-EncryptedMemoriesAccountStorageOnlyBackupFixture") {
                        kinds = [.accountStorage]
                    } else if arguments.contains("-EncryptedMemoriesRemoteServiceOnlyBackupFixture") {
                        kinds = [.remoteService]
                    } else if arguments.contains("-EncryptedMemoriesNoUserResolvableBackupFixture") {
                        kinds = [.network, .deletedElsewhere, .unsupported]
                    } else {
                        kinds = [.network, .accountStorage, .deletedElsewhere, .unsupported]
                    }
                    installed = controller.installFailedItemsFixtureForTesting(kinds: kinds)
                } else {
                    let large = ProcessInfo.processInfo.arguments.contains(
                        "-EncryptedMemoriesDeletedBackupLargeFixture")
                    installed = controller.installDeletedElsewhereFixtureForTesting(count: large ? 5_000 : 1)
                }
                guard installed else { return }
                backupFixture = controller
                runtime.libraryModel.installIsolatedBackupForTesting(controller)
            } catch {
                assertionFailure("The deleted backup fixture could not be installed")
            }
        }

        /// One Apple Photos photo that waits for its upload in the grid while the person paused the backup.
        private func installPausedBackupFixture() {
            let directory = cacheDirectory.appendingPathComponent("paused-backup", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let defaults = UserDefaults(suiteName: "paused-backup-fixture"),
                    let store = PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative)
                else { return }
                defaults.removePersistentDomain(forName: "paused-backup-fixture")
                let controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: MobileFixtureBackupBackend(), uploader: MobileFixtureBackupBackend(),
                    pendingStore: store, requiresPendingStore: true)
                guard controller.installPausedBackupFixtureForTesting() else { return }
                backupFixture = controller
                runtime.libraryModel.installIsolatedPendingBackupForTesting(
                    controller, store: store, remote: MobileFixturePendingRemoteEffects())
                if ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesExcludedBackupFixture") {
                    excludeWaitingPhoto()
                }
            } catch {
                assertionFailure("The paused backup fixture could not be installed")
            }
        }

        /// The person deleted the waiting photo and removed it from Recently Deleted: the Backup settings list it as
        /// excluded from the backup.
        private func excludeWaitingPhoto() {
            let uid = PhotoUID(localPending: .photoLibrary, identifier: "fixture-paused-photo")
            let model = runtime.libraryModel
            Task { @MainActor in
                // The pending grid starts its coordinator on its own; a delete before it shows the photo does nothing.
                @MainActor func shows() -> Bool {
                    model.pendingGrid?.pendingSnapshot.tiles.contains { $0.item.uid == uid } == true
                }
                for _ in 0..<200 where !shows() { try? await Task.sleep(for: .milliseconds(50)) }
                guard await model.pendingGrid?.delete([uid]) == true else { return }
                _ = await model.pendingGrid?.removeFromTrashList([uid])
            }
        }

        /// Installs only the library content into an isolated model (no session, no shared runtime): for probes that
        /// host one production screen in a test window.
        func install(into model: MobileLibraryModel) {
            model.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
                thumbnailFeed: feed, thumbnailCache: cache)
        }

        func install(
            into model: MobileLibraryModel,
            backend: any PhotosBackend,
            sections: [TimelineSection],
            thumbnailFeed: UIKitThumbnailFeed,
            thumbnailCache: ThumbnailCache
        ) {
            model.installIsolatedLibrary(
                session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
                thumbnailFeed: thumbnailFeed, thumbnailCache: thumbnailCache)
        }

        /// Clears fixture state through the session observer without requesting another persistent-data purge.
        func clearSession() {
            runtime.sessionModel.installIsolatedSession(nil)
        }

        func removeCache() {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private struct MobileFixtureBackupBackend: PhotoUploading, UploadIdentityResolving {
        let capabilities = UploadBackendCapabilities(
            canUpload: true, supportsCancel: true,
            supportsPauseResume: false, supportsResumeAcrossRelaunch: false)

        func upload(
            _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID { throw MobileFixtureError.unavailable }
        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            try await UploadNetworkAdmission().reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
        }
        func cancel(token: UUID) async {}
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw MobileFixtureError.unavailable
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity,
            remoteVolumeID: String, remoteLinkID: String
        ) async throws { throw MobileFixtureError.unavailable }
    }

    /// Proton effects of pending photos on an offline account: every call waits for a retry.
    private struct MobileFixturePendingRemoteEffects: PendingRemoteEffects {
        func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .init(retry: Set(uids)) }
        func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .init(retry: Set(uids)) }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .retry }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .retry }
    }

    /// Remote album operations of an offline account: every call fails.
    private struct MobileFixtureAlbumSyncRemoteOps: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { throw MobileFixtureError.unavailable }
        func createAlbum(name: String) async throws -> String { throw MobileFixtureError.unavailable }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { throw MobileFixtureError.unavailable }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            throw MobileFixtureError.unavailable
        }
    }

    /// Groups of exact copies in memory. A merge keeps the chosen photo and moves the other copies to Trash.
    /// `checking` leaves the library check running: its index is not built, and its build stays at 1,234 of 15,000.
    /// The first copy of each group is a favorite in an own album, so the screen shows badges and a reason.
    final class MobileFixtureDuplicates: ExactDuplicateMerging, @unchecked Sendable {
        func excludingMerges(_ body: () async throws -> Void) async throws { try await body() }
        private let lock = NSLock()
        private var groups: [ExactDuplicateGroup]
        private let checking: Bool
        private let dates: [PhotoUID: Date]
        /// A scan after the first load of the screen leaves out the last group, so a UI test sees whether the
        /// screen scanned again. The Collections entry does not scan unchecked candidates.
        private let rescanDropsLastGroup: Bool
        /// Holds the metadata check so the UI test can inspect its progress-only state.
        private let rankDelay: Duration?
        private let scanDelay: Duration?
        /// The time that each merge batch takes. Nil merges at once.
        private let mergeDelay: Duration?
        /// False stands for a merge whose check cannot run yet, which keeps Recently Deleted from being emptied.
        private let confirmsNoPendingMerges: Bool
        private var scans = 0
        private let invalidatingMergeReloadFails: Bool
        private var reloadMustFail = false
        private let buildInterruptions: Int
        private var buildCalls = 0
        private var indexComplete = false
        /// One failed group on the first merge, so the real alert can retry it.
        private var mergeFailure: URLError.Code?

        init(
            groups members: [[PhotoUID]], checking: Bool = false, captureDates: [PhotoUID: Date] = [:],
            rescanDropsLastGroup: Bool = false, scanDelay: Duration? = nil, rankDelay: Duration? = nil,
            mergeDelay: Duration? = nil,
            confirmsNoPendingMerges: Bool = true, invalidatingMergeReloadFails: Bool = false,
            buildInterruptions: Int = 0, mergeFailure: URLError.Code? = nil
        ) {
            groups = members.enumerated().map { index, members in
                ExactDuplicateGroup(contentHash: "fixture-copies-\(index)", hashKeyEpoch: "fixture", members: members)
            }
            self.checking = checking
            dates = captureDates
            self.rescanDropsLastGroup = rescanDropsLastGroup
            self.rankDelay = rankDelay
            self.scanDelay = scanDelay
            self.mergeDelay = mergeDelay
            self.confirmsNoPendingMerges = confirmsNoPendingMerges
            self.invalidatingMergeReloadFails = invalidatingMergeReloadFails
            self.buildInterruptions = buildInterruptions
            self.mergeFailure = mergeFailure
        }

        func confirmNoPendingMerges() async -> Bool { confirmsNoPendingMerges }

        func duplicateGroups(
            progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
        ) async throws -> ExactDuplicateScan {
            if let scanDelay { try await Task.sleep(for: scanDelay) }
            let (groups, coverage) = try lock.withLock {
                if reloadMustFail {
                    reloadMustFail = false
                    throw MobileFixtureError.unavailable
                }
                scans += 1
                return (
                    rescanDropsLastGroup && scans > 1 ? Array(groups.dropLast()) : groups,
                    checking && !indexComplete ? ExactDuplicateCoverage.indexing : .complete
                )
            }
            let sizes: [Int64] = [5_200_000, 387_000]
            return ExactDuplicateScan(
                groups: groups, coverage: coverage,
                byteSizes: Dictionary(
                    groups.enumerated().map { ($1.id, sizes[$0 % sizes.count]) },
                    uniquingKeysWith: { first, _ in first }))
        }

        func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        }

        func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
            Dictionary(
                members.compactMap { member in dates[member].map { (member, $0) } },
                uniquingKeysWith: { first, _ in first })
        }

        func rankMembers(
            of groups: [ExactDuplicateGroup], ranked: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
        ) async {
            if let rankDelay {
                do { try await Task.sleep(for: rankDelay) } catch { return }
            }
            let facts = groups.map { group in
                let memberFacts = group.members.enumerated().map { index, member in
                    (
                        member,
                        ExactDuplicateKeepFacts(
                            isInOwnAlbum: index == 0, isFavorite: index == 0, isNamedByManifest: false,
                            captureDate: dates[member])
                    )
                }
                return (group.id, Dictionary(memberFacts, uniquingKeysWith: { first, _ in first }))
            }
            // The copies of a group share their metadata, so every group stays whole.
            let fingerprints = groups.map { group in
                (group.id, Dictionary(uniqueKeysWithValues: group.members.map { ($0, ExactDuplicateFingerprint()) }))
            }
            await ranked(
                ExactDuplicateRankingPage(
                    members: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) }),
                    groupCount: groups.count, facts: Dictionary(uniqueKeysWithValues: facts),
                    fingerprints: Dictionary(uniqueKeysWithValues: fingerprints)))
        }

        func prepareIndex(
            progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
        ) async throws -> Bool {
            guard checking else { return false }
            if buildInterruptions > 0 {
                return try lock.withLock {
                    buildCalls += 1
                    if buildCalls <= buildInterruptions { throw CancellationError() }
                    indexComplete = true
                    return true
                }
            }
            await progress(.init(phase: .indexing, completed: 1_234, total: 15_000))
            try await Task.sleep(for: .seconds(3_600))
            return false
        }

        func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
            if let mergeDelay { try? await Task.sleep(for: mergeDelay) }
            if invalidatingMergeReloadFails {
                lock.withLock { reloadMustFail = true }
                return requests.map { _ in .success(.skipped(.preselectionChanged)) }
            }
            let failure = lock.withLock {
                let failure = mergeFailure
                mergeFailure = nil
                let failedID = failure == nil ? nil : requests.first?.group.id
                groups.removeAll { group in
                    group.id != failedID && requests.contains { $0.group.id == group.id }
                }
                return failure
            }
            return requests.map { request in
                if let failure, request.group.id == requests.first?.group.id {
                    return .failure(URLError(failure))
                }
                return .success(
                    .merged(
                        kept: request.kept, trashed: request.group.members.filter { $0 != request.kept },
                        keptDuplicates: [:]))
            }
        }
    }

    enum MobileFixtureError: Error, VideoPlaybackClassifiable {
        case bitmap
        case unavailable
        case pendingAccountPurge
        case rateLimited
        case permanentVideoFailure

        var videoPlaybackError: VideoPlaybackError? {
            switch self {
            case .rateLimited: .quotaOrRateLimited
            case .permanentVideoFailure: .decryptionFailed
            default: nil
            }
        }
    }

    /// Owned albums in memory, so UI tests can create albums and add photos without an account.
    final class MobileFixtureAlbums: AlbumCatalogBackend, AlbumWriteBackend, @unchecked Sendable {
        static let albumTitle = "Fixture Album"
        static let capabilities = AlbumCapabilities(
            canList: true, canCreate: true, canAddPhotos: true, canSetCover: false, canReadMemberships: true)

        private let lock = NSLock()
        private let startsEmpty: Bool
        private var createdAlbums: [(id: AlbumID, title: String)] = []
        private var members: [AlbumID: Set<PhotoUID>] = [:]

        init(startsEmpty: Bool = false) { self.startsEmpty = startsEmpty }

        func listAlbums() async throws -> [AlbumSummary] {
            lock.withLock {
                ((startsEmpty ? [] : [(id: "fixture-album", title: Self.albumTitle)]) + createdAlbums).map { album in
                    AlbumSummary(
                        id: album.id, title: album.title, photoCount: members[album.id]?.count ?? 0, coverPhotoID: nil)
                }
            }
        }
        func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] { [] }
        func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {}
        func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
            let members = lock.withLock { self.members }
            return Dictionary(
                uniqueKeysWithValues: photoUIDs.map { uid in
                    let albums = Set(
                        members.compactMap { albumID, photos in
                            photos.contains(uid) ? AlbumNodeIdentifier(volumeID: uid.volumeID, nodeID: albumID) : nil
                        })
                    return (uid, albums)
                })
        }
        func createAlbum(name: String) async throws -> AlbumID {
            lock.withLock {
                let id = "fixture-created-album-\(createdAlbums.count)"
                createdAlbums.append((id: id, title: name))
                return id
            }
        }
        func deleteAlbum(albumID: AlbumID) async throws { throw MobileFixtureError.unavailable }
        func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
            lock.withLock { members[albumID, default: []].formUnion(photoUIDs) }
        }
        func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
            throw MobileFixtureError.unavailable
        }
        func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws { throw MobileFixtureError.unavailable }
    }

    final class MobileFixtureTrashState: @unchecked Sendable {
        private let lock = NSLock()
        private var emptied = false

        var isEmptied: Bool {
            get { lock.withLock { emptied } }
            set { lock.withLock { emptied = newValue } }
        }
    }

    /// Every provider of the account backend, answered from memory. Media beyond thumbnails is unavailable, which
    /// the production viewer handles like an offline account.
    struct MobileFixtureBackend: PhotosBackend, LibraryChangeTokenProvider {
        let sections: [TimelineSection]
        let thumbnails: [PhotoUID: Data]
        var timelineLoader: (@Sendable () async throws -> TimelineLoadSnapshot)? = nil
        var changeTokenLoader: (@Sendable () async throws -> String)? = nil
        var cachedTimelineLoader: (@Sendable () async -> CachedTimelineSnapshot?)? = nil
        var favoriteLoader: (@Sendable () async throws -> Set<PhotoUID>)? = nil
        var favoriteWriter: (@Sendable ([PhotoUID], Bool) async throws -> Void)? = nil
        var trashEmptier: (@Sendable () async throws -> Void)? = nil
        var streamingAssetLoader: (@Sendable (PhotoUID) async throws -> StreamingVideoAsset)? = nil
        /// Overrides the empty default burst-group answer, for viewer share/export wiring tests.
        var burstGroupLoader: (@Sendable (PhotoUID) async throws -> [PhotoItem])? = nil
        /// Recently Deleted lists every fixture photo until it is emptied.
        let trashState = MobileFixtureTrashState()

        func loadTimeline() async throws -> [TimelineSection] { try await loadTimelineSnapshot().sections }
        func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
            if let timelineLoader { return try await timelineLoader() }
            return TimelineLoadSnapshot(sections: sections, validationToken: "fixture")
        }
        func libraryChangeToken() async throws -> String { try await changeTokenLoader?() ?? "fixture" }
        func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
            guard let cachedTimelineLoader else { return nil }
            return await cachedTimelineLoader()
        }
        func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
            filter == .trash && trashState.isEmptied ? [] : sections
        }

        func thumbnail(for uid: PhotoUID) async throws -> Data {
            guard let data = thumbnails[uid] else { throw MobileFixtureError.unavailable }
            return data
        }

        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            var missing: [PhotoUID: String] = [:]
            for uid in uids {
                if let data = thumbnails[uid] {
                    onLoaded(uid, data)
                } else {
                    missing[uid] = "fixture has no thumbnail"
                }
            }
            return ThumbnailBatchLoadResult(itemErrors: missing)
        }

        func preview(for uid: PhotoUID) async throws -> Data { try await thumbnail(for: uid) }
        func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            throw MobileFixtureError.unavailable
        }
        func streamOriginalBytes(
            for uid: PhotoUID, onChunk: @escaping @Sendable (Data) async throws -> Void,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            throw MobileFixtureError.unavailable
        }
        func writeOriginal(
            for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
        )
            async throws
        {
            throw MobileFixtureError.unavailable
        }
        /// Without the scenario argument the video never prepares and fails in a changeable way, as before. With
        /// `-EncryptedMemoriesVideoFailureScenario` the first preparation hits a rate limit, which the viewer retries
        /// silently, the second fails in a way that a new attempt can change, and every later one fails for good.
        func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
            if let streamingAssetLoader { return try await streamingAssetLoader(uid) }
            guard ProcessInfo.processInfo.arguments.contains("-EncryptedMemoriesVideoFailureScenario") else {
                throw MobileFixtureError.unavailable
            }
            let attempt = streamingAttempts.withLock { count in
                count += 1
                return count
            }
            switch attempt {
            case 1: throw MobileFixtureError.rateLimited
            case 2: throw MobileFixtureError.unavailable
            default: throw MobileFixtureError.permanentVideoFailure
            }
        }
        private let streamingAttempts = OSAllocatedUnfairLock(initialState: 0)
        func prefetchEncrypted(for uid: PhotoUID) async throws {}
        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            guard uid.nodeID == MobileSignedInFixture.videoNodeID else {
                return PhotoMetadata(
                    filename: "\(uid.nodeID).jpg", mimeType: "image/jpeg", pixelWidth: 160, pixelHeight: 160)
            }
            return PhotoMetadata(
                filename: "\(uid.nodeID).mov", mimeType: "video/quicktime", pixelWidth: 160, pixelHeight: 160)
        }
        func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
            try await burstGroupLoader?(uid) ?? []
        }
        func favoriteUIDs() async throws -> Set<PhotoUID> {
            try await favoriteLoader?() ?? []
        }
        func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws {
            try await favoriteWriter?(uids, favorite)
        }
        func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
            PhotoLibrarySaveResult(saved: Set(uids), failed: [])
        }
        func trash(_ uids: [PhotoUID]) async throws {}
        func restore(_ uids: [PhotoUID]) async throws {}
        func emptyTrash() async throws {
            try await trashEmptier?()
            trashState.isEmptied = true
        }
        func metadataRowCount() async -> Int { sections.reduce(0) { $0 + $1.items.count } }
    }

    /// The fixture reverts at once, or refuses every revert when the UI test passes `revertFixtureFails`.
    extension MobileFixtureBackend: EditedPhotoReverting {
        func revertToOriginal(of main: PhotoItem, original: PhotoItem) async throws {
            if MobileUITestLaunch.revertFixtureFails { throw MobileFixtureRevertRefused() }
        }
    }

    private struct MobileFixtureRevertRefused: Error {}

    /// Every fixture photo is an edit with an original, so the UI tests can show it; the video has none.
    extension MobileFixtureBackend: EditedPhotoOriginalProviding {
        func editedOriginal(of item: PhotoItem) async throws -> PhotoItem? {
            guard !item.isVideo else { return nil }
            return PhotoItem(
                uid: MobileSignedInFixture.editedOriginalUID, captureTime: item.captureTime, mediaType: "image/jpeg")
        }
    }
#endif
