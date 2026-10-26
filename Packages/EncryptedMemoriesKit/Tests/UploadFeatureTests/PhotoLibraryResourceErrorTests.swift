import Photos
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import PhotosCore
@testable import UploadCore

final class PhotoLibraryResourceErrorTests: XCTestCase {
    func testOnlyAPhotoThatAnAnsweringLibraryNoLongerListsLeavesTheCatalog() {
        // A library without access, on an offline volume or not loaded yet proves nothing about a photo.
        for listed in [true, false] {
            XCTAssertFalse(
                PhotoLibraryResourceResolver.photosNoLongerLists(
                    "asset", libraryAnswers: { false }, listsAsset: { _ in listed }))
        }
        // A photo that Photos still lists, for example a series photo of another main photo, stays.
        XCTAssertFalse(
            PhotoLibraryResourceResolver.photosNoLongerLists(
                "asset", libraryAnswers: { true }, listsAsset: { _ in true }))
        var asked: [String] = []
        XCTAssertTrue(
            PhotoLibraryResourceResolver.photosNoLongerLists(
                "asset", libraryAnswers: { true },
                listsAsset: {
                    asked.append($0)
                    return false
                }))
        XCTAssertEqual(asked, ["asset"], "Photos is asked about this photo")
    }

    func testAnUnreadableResourceOfAListedPhotoIsCheckedAgainBeforeItCountsAsMissing() {
        // The asset still exists; only its file cannot be read. It takes the checks of a missing resource, so it
        // never leaves the queue and returns through catalog recovery on every pass.
        for code in [PHPhotosError.Code.identifierNotFound, .invalidResource] {
            let native = NSError(domain: PHPhotosErrorDomain, code: code.rawValue)

            let normalized = PhotoLibraryResourceResolver.normalizedPhotoKitError(native, filename: "IMG_0001.jpeg")

            XCTAssertEqual(normalized as? UploadError, .sourceReportedMissing("IMG_0001.jpeg"), "\(code)")
        }
    }

    func testALiveAssetWithoutItsMainFileIsCheckedAgainButASeriesPhotoOfAnotherMainHasNoWork() throws {
        func info(_ roles: [PhotoBackupAssetInfo.Resource.Role]) -> PhotoBackupAssetInfo {
            PhotoBackupAssetInfo(
                localIdentifier: "asset", creationDate: Date(timeIntervalSince1970: 100),
                modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
                durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: roles.map { .init(role: $0, originalFilename: "IMG_0003.HEIC", mimeType: "image/heic") })
        }

        XCTAssertNotNil(
            try PhotoLibraryResourceResolver.livePlan(for: info([.originalPhoto]), filename: "IMG_0003.HEIC"))
        XCTAssertNil(
            try PhotoLibraryResourceResolver.livePlan(
                for: info([.originalPhoto, .burstMainReference]), filename: "IMG_0003.HEIC"),
            "a series photo of another main photo has no backup work of its own")
        XCTAssertThrowsError(
            try PhotoLibraryResourceResolver.livePlan(for: info([.adjustmentData]), filename: "IMG_0003.HEIC")
        ) { error in
            XCTAssertEqual(error as? UploadError, .sourceReportedMissing("IMG_0003.HEIC"))
        }
    }

    func testOnlyTheLivePhotoVideoThatPhotosReportsMissingOnTheLastCheckIsLeftOut() throws {
        func plan(livePlaybackOff: Bool = false) throws -> PhotoBackupExportPlan {
            let resources: [PhotoBackupAssetInfo.Resource] = [
                .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
                .init(role: .originalPhoto, originalFilename: "IMG_0004.HEIC", mimeType: "image/heic"),
                .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil),
                .init(role: .pairedVideo, originalFilename: "IMG_0004.MOV", mimeType: "video/quicktime"),
            ]
            return try XCTUnwrap(
                PhotoBackupAssetPlanner.exportPlan(
                    for: PhotoBackupAssetInfo(
                        localIdentifier: "asset", creationDate: Date(timeIntervalSince1970: 100),
                        modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
                        durationSeconds: 0, isLivePhoto: !livePlaybackOff, isVideo: false, resources: resources,
                        hasAdjustments: true, livePlaybackOff: livePlaybackOff)))
        }
        let live = try plan()
        let video = try XCTUnwrap(live.secondaries.first { $0.sourceResource == .livePairedVideo })
        let missing = UploadError.sourceReportedMissing(video.uploadFilename)
        func omits(_ item: PhotoBackupExportPlan.Item, _ error: any Error, _ allowed: Bool = true) -> Bool {
            PhotoLibraryResourceResolver.omitsSecondary(item, failingWith: error, omittingMissingPairedVideo: allowed)
        }

        XCTAssertTrue(omits(video, missing))
        XCTAssertTrue(
            omits(video, photoKitFailure(.missingResource, for: video.uploadFilename)),
            "PhotoKit's missing resource, as the identity pass reports it")
        XCTAssertFalse(omits(video, missing, false), "before the last check the video keeps its failure")
        // A video that waits for iCloud, a denied read, or any other failure keeps its handling.
        for error: any Error in [
            UploadError.sourceUnavailable(video.uploadFilename), UploadError.permissionDenied(video.uploadFilename),
            UploadError.fileMissing(video.uploadFilename), UploadError.backend("read failed"), CancellationError(),
            photoKitFailure(.networkAccessRequired, for: video.uploadFilename),
        ] {
            XCTAssertFalse(omits(video, error), "\(error)")
        }
        // Every other resource keeps its failure: the edit's original, its adjustments, a series photo, and the
        // video of a photo whose Live effect is off, which carries no Live Photo tag.
        let others = live.secondaries.filter { $0.sourceResource != .livePairedVideo }
        XCTAssertEqual(others.count, 2)
        let liveOffVideo = try XCTUnwrap(try plan(livePlaybackOff: true).secondaries.first { $0.role == .pairedVideo })
        XCTAssertNotEqual(liveOffVideo.sourceResource, .livePairedVideo)
        let member = PhotoBackupExportPlan.Item(
            role: .burstMember, uploadFilename: "IMG_0005.HEIC", mimeType: "image/heic",
            sourceResource: .burstMember(ordinal: 0))
        for item in others + [liveOffVideo, member, live.primary] {
            XCTAssertFalse(omits(item, UploadError.sourceReportedMissing(item.uploadFilename)), item.uploadFilename)
        }
    }

    private func photoKitFailure(_ code: PHPhotosError.Code, for name: String) -> any Error {
        PhotoLibraryResourceResolver.normalizedPhotoKitError(
            NSError(domain: PHPhotosErrorDomain, code: code.rawValue), filename: name)
    }

    func testAMissingPhotoKitResourceIsCheckedAgainBeforeThePhotoCountsAsGone() {
        // A download from iCloud that stops part-way can report a missing resource too.
        let native = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.missingResource.rawValue)

        let normalized = PhotoLibraryResourceResolver.normalizedPhotoKitError(native, filename: "IMG_0001.jpeg")

        XCTAssertEqual(normalized as? UploadError, .sourceReportedMissing("IMG_0001.jpeg"))
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(normalized))
    }

    func testPhotoKitWaitsAreSourceWaitsNotProtonConnectionFailures() {
        let codes: [PHPhotosError.Code] = [
            .networkAccessRequired, .networkError, .libraryVolumeOffline, .operationInterrupted,
        ]
        for code in codes {
            let native = NSError(
                domain: PHPhotosErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "offline"])

            let normalized = PhotoLibraryResourceResolver.normalizedPhotoKitError(native, filename: "IMG_0002.mov")

            XCTAssertEqual(normalized as? UploadError, .sourceUnavailable("IMG_0002.mov"), "\(code)")
            // The wait is about Photos: it must not lower the upload concurrency for photos on the device.
            XCTAssertFalse(BackupSyncRunner.isTransientNetwork(normalized), "\(code) is no connection failure")
        }
    }

    func testPhotoKitRequestActivityExtendsItsStallDeadline() async throws {
        let clock = ManualUptime()
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            stallTimeout: 180,
            pollInterval: 5,
            automaticallyStartsWatchdog: false,
            now: { clock.value },
            cancelRequest: { cancellations.record($0) }
        )
        let request = Task {
            try await liveness.waitForCompletion { 41 }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }

        clock.advance(by: 179)
        XCTAssertFalse(liveness.checkForStall())
        liveness.markActivity()
        clock.advance(by: 179)
        XCTAssertFalse(liveness.checkForStall())

        liveness.complete(error: nil)
        try await request.value
        XCTAssertEqual(cancellations.values, [])
    }

    func testStalledPhotoKitRequestReleasesHeavyPermitAndRetriesAsTransport() async throws {
        let clock = ManualUptime()
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            stallTimeout: 180,
            pollInterval: 5,
            automaticallyStartsWatchdog: false,
            now: { clock.value },
            cancelRequest: { cancellations.record($0) }
        )
        // In the background backup preparation runs alone, so the following permit waits for the stalled one.
        let coordinator = LibraryResourceCoordinator(
            runtimeState: LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted)))
        let work = LibraryWorkRequest(
            workload: .backupMaterialization,
            intent: .automatic,
            memoryClass: .large
        )
        let stalled = Task {
            try await coordinator.withHeavyPermit(work) { _ in
                try await liveness.waitForCompletion { 42 }
            }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }
        let following = Task {
            try await coordinator.withHeavyPermit(work) { _ in "continued" }
        }

        clock.advance(by: 180)
        XCTAssertTrue(liveness.checkForStall())
        do {
            try await stalled.value
            XCTFail("expected PhotoKit inactivity timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertTrue(BackupSyncRunner.isTransientNetwork(error))
        }
        let followingResult = try await following.value
        XCTAssertEqual(followingResult, "continued")
        XCTAssertEqual(cancellations.values, [42])

        // A late native completion after cancellation is ignored and cannot double-resume.
        liveness.complete(error: nil)
        XCTAssertEqual(cancellations.values, [42])
    }

    func testCancellingPhotoKitWaitResumesWithoutNativeCompletion() async {
        let cancellations = RequestCancellations()
        let liveness = PhotoKitResourceRequestLivenessGuard<Int>(
            automaticallyStartsWatchdog: false,
            cancelRequest: { cancellations.record($0) }
        )
        let request = Task {
            try await liveness.waitForCompletion { 43 }
        }
        while !liveness.hasRegisteredRequest { await Task.yield() }

        request.cancel()
        do {
            try await request.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation itself resumes the callback bridge.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(cancellations.values, [43])
    }
}

private final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0

    var value: TimeInterval { lock.withLock { stored } }

    func advance(by interval: TimeInterval) {
        lock.withLock { stored += interval }
    }
}

private final class RequestCancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    func record(_ requestID: Int) {
        lock.withLock { stored.append(requestID) }
    }

    var values: [Int] { lock.withLock { stored } }
}
