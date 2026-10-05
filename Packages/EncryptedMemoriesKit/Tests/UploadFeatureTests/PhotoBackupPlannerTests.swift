import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import XCTest

@testable import UploadCore

/// Pure planning layer of the PhotoKit adapter: candidate/fingerprint/export decisions over
/// platform-neutral asset descriptions - no PhotoKit, no photo access, runs everywhere.
final class PhotoBackupPlannerTests: XCTestCase {
    private func info(
        id: String = "asset-1",
        created: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_100),
        width: Int = 4032, height: Int = 3024,
        duration: Double = 0,
        live: Bool = false,
        video: Bool = false,
        resources: [PhotoBackupAssetInfo.Resource]
    ) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: created, modificationDate: modified,
            pixelWidth: width, pixelHeight: height, durationSeconds: duration,
            isLivePhoto: live, isVideo: video, resources: resources
        )
    }

    // MARK: - Edit readiness

    private let now = Date(timeIntervalSince1970: 1_700_001_000)
    private let original = PhotoBackupAssetInfo.Resource(
        role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: "image/heic")
    private let render = PhotoBackupAssetInfo.Resource(
        role: .fullSizePhoto, originalFilename: "FullSizeRender.heic", mimeType: "image/heic")

    private func edited(
        secondsAgo: TimeInterval, hasAdjustments: Bool = true, rendered: Bool = true
    ) -> PhotoBackupAssetInfo {
        var asset = info(resources: rendered ? [original, render] : [original])
        asset.hasAdjustments = hasAdjustments
        asset.adjustmentTimestamp = now.addingTimeInterval(-secondsAgo)
        return asset
    }

    func testAPhotoNeverEditedIsReadyAtOnce() {
        XCTAssertNil(PhotoBackupAssetPlanner.notReadyUntil(for: info(resources: [original]), now: now))
    }

    func testQuickSuccessiveEditsWaitForAQuietPeriod() {
        XCTAssertEqual(
            PhotoBackupAssetPlanner.notReadyUntil(for: edited(secondsAgo: 2), now: now), now.addingTimeInterval(3))
        XCTAssertNil(PhotoBackupAssetPlanner.notReadyUntil(for: edited(secondsAgo: 6), now: now))
    }

    func testAnUndoWaitsForTheQuietPeriodToo() {
        // An undo removes the adjustments and moves the timestamp.
        let reverted = edited(secondsAgo: 1, hasAdjustments: false, rendered: false)
        XCTAssertEqual(PhotoBackupAssetPlanner.notReadyUntil(for: reverted, now: now), now.addingTimeInterval(4))
        let settled = edited(secondsAgo: 30, hasAdjustments: false, rendered: false)
        XCTAssertNil(PhotoBackupAssetPlanner.notReadyUntil(for: settled, now: now))
    }

    func testAnEditWithoutItsRenderedFileWaitsInsteadOfUploadingTheOriginal() {
        let rendering = edited(secondsAgo: 20, rendered: false)
        XCTAssertEqual(
            PhotoBackupAssetPlanner.notReadyUntil(for: rendering, now: now), now.addingTimeInterval(15),
            "the original must not replace the edit while Photos still renders it")
        let abandoned = edited(secondsAgo: 200, rendered: false)
        XCTAssertNil(
            PhotoBackupAssetPlanner.notReadyUntil(for: abandoned, now: now), "the backup never waits for good")
    }

    func testTheRenderWaitEndsAtItsLimit() {
        XCTAssertEqual(
            PhotoBackupAssetPlanner.notReadyUntil(for: edited(secondsAgo: 110, rendered: false), now: now),
            now.addingTimeInterval(10))
    }

    func testAnEditTimestampAheadOfTheClockDoesNotHoldThePhotoBack() {
        // The device clock ran an hour ahead during the edit.
        XCTAssertNil(PhotoBackupAssetPlanner.notReadyUntil(for: edited(secondsAgo: -3600), now: now))
        XCTAssertNil(
            PhotoBackupAssetPlanner.notReadyUntil(for: edited(secondsAgo: -3600, rendered: false), now: now))
    }

    func testAnEditedVideoWaitsForItsRenderedVideo() {
        var video = info(
            video: true,
            resources: [.init(role: .originalVideo, originalFilename: "IMG_2.MOV", mimeType: "video/quicktime")])
        video.hasAdjustments = true
        video.adjustmentTimestamp = now.addingTimeInterval(-20)
        XCTAssertNotNil(PhotoBackupAssetPlanner.notReadyUntil(for: video, now: now))
        video.resources.append(
            .init(role: .fullSizeVideo, originalFilename: "FullSizeRender.mov", mimeType: "video/quicktime"))
        XCTAssertNil(PhotoBackupAssetPlanner.notReadyUntil(for: video, now: now))
    }

    func testOriginalFilenameAndExtensionArePreserved() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1234.HEIC", mimeType: "image/heic")
        ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.uploadFilename, "IMG_1234.HEIC")
        XCTAssertEqual(plan.primary.mimeType, "image/heic")
        XCTAssertEqual(plan.primary.role, .originalPhoto)
        XCTAssertTrue(plan.secondaries.isEmpty)
    }

    func testEditedPhotoExportsCurrentBytesAndPreservesOriginalResources() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1234.HEIC", mimeType: "image/heic"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: "application/octet-stream"),
        ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.role, .fullSizePhoto, "the CURRENT user-visible bytes are backed up")
        XCTAssertEqual(
            plan.primary.uploadFilename, "IMG_1234.jpg",
            "the edited render keeps the original basename but gets an honest extension")
        XCTAssertEqual(
            plan.secondaries.map { "\($0.role.rawValue):\($0.uploadFilename)" },
            ["originalPhoto:IMG_1234.HEIC", "adjustmentData:Adjustments.plist"],
            "the untouched original and edit metadata must remain attached to the compound"
        )
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: asset)?.snapshot.resourceCount, 3)
    }

    func testRawAlternateIsBackedUpAsPartOfTheCompound() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_7777.HEIC", mimeType: "image/heic"),
            .init(role: .alternatePhoto, originalFilename: "IMG_7777.DNG", mimeType: "image/x-adobe-dng"),
        ])

        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))

        XCTAssertEqual(plan.primary.uploadFilename, "IMG_7777.HEIC")
        XCTAssertEqual(plan.secondaries.map(\.uploadFilename), ["IMG_7777.DNG"])
        XCTAssertEqual(plan.secondaries.map(\.sourceResource.rawValue), ["photoKit.alternatePhoto.0"])
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: asset)?.snapshot.resourceCount, 2)
    }

    func testVideoPrefersCurrentRenderAndKeepsMOV() throws {
        let asset = info(
            video: true,
            resources: [
                .init(role: .originalVideo, originalFilename: "IMG_5000.MOV", mimeType: "video/quicktime")
            ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.uploadFilename, "IMG_5000.MOV")
        XCTAssertEqual(plan.primary.mimeType, "video/quicktime")
    }

    func testLivePhotoBecomesTwoResourceCompound() throws {
        let asset = info(
            live: true,
            resources: [
                .init(role: .originalPhoto, originalFilename: "IMG_2000.HEIC", mimeType: "image/heic"),
                .init(role: .pairedVideo, originalFilename: "IMG_2000.MOV", mimeType: "video/quicktime"),
            ])
        let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: asset))
        XCTAssertEqual(candidate.snapshot.resourceCount, 2)
        XCTAssertEqual(candidate.snapshot.source.kind, .photoLibraryAsset)
        XCTAssertEqual(candidate.snapshot.source.resource, .primary)
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.secondaries.first?.uploadFilename, "IMG_2000.MOV")
    }

    func testTheLivePhotoVideoUploadsAfterEveryOtherRelatedFile() throws {
        // Proton lists the newest related file first; an app that plays the first one must get the video.
        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_2000.HEIC", mimeType: "image/heic"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.heic", mimeType: "image/heic"),
            .init(role: .pairedVideo, originalFilename: "IMG_2000.MOV", mimeType: "video/quicktime"),
            .init(role: .fullSizePairedVideo, originalFilename: "FullSizeRender.mov", mimeType: "video/quicktime"),
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist"),
            .init(role: .other, originalFilename: "Other.dat"),
        ]
        let live = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info(live: true, resources: resources)))
        XCTAssertEqual(
            live.secondaries.map(\.role),
            [.originalPhoto, .fullSizePairedVideo, .adjustmentData, .other, .pairedVideo])
        XCTAssertEqual(live.secondaries.last?.sourceResource, .livePairedVideo)
    }

    func testCatalogRoundTripKeepsTheRevisionOfAnEditWithoutItsRenderedFile() throws {
        let asset = edited(secondsAgo: 600, rendered: false)
        let entry = PhotoLibraryCatalogMapper.entry(for: asset, observedAt: Date())
        let replayed = PhotoLibraryCatalogMapper.info(for: entry)

        XCTAssertEqual(
            try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: replayed)).snapshot.revision,
            try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: asset)).snapshot.revision,
            "a replay that plans the revision with the rendered file completes it before that file exists")
    }

    func testCatalogRoundTripRetainsExternalIdentityForProofReplay() throws {
        var asset = info(
            modified: Date(timeIntervalSince1970: 1_700_000_100.1234),
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_1.HEIC")]
        )
        asset.cloudIdentifier = "icloud-asset"
        let entry = PhotoLibraryCatalogMapper.entry(for: asset, observedAt: Date())
        let replayed = PhotoLibraryCatalogMapper.info(for: entry)
        let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: replayed))

        XCTAssertEqual(candidate.snapshot.externalIdentity?.identifier, "icloud-asset")
        XCTAssertEqual(
            candidate.snapshot.externalIdentity,
            UploadBackupExternalIdentity(
                identifier: "icloud-asset",
                modificationDate: Date(timeIntervalSince1970: 1_700_000_100.1234)
            )
        )
    }

    func testApplePhotosTraitsBecomeTheProtonTagsOfTheirCollections() {
        XCTAssertEqual(PhotoBackupAssetTraits().protonTags, [], "a plain photo carries no tag of its own")
        let everything = PhotoBackupAssetTraits(
            isFavorite: true, isScreenshot: true, isPortrait: true, isPanorama: true, isRaw: true)
        XCTAssertEqual(
            everything.protonTags, [PhotoTag.favorites, .screenshots, .portraits, .panoramas, .raw].map(\.rawValue))
        XCTAssertEqual(PhotoBackupAssetTraits(isFavorite: true).protonTags, [PhotoTag.favorites.rawValue])
    }

    func testUneditedAssetGetsStableFingerprintEvidence() {
        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: "image/heic")
        ]
        let base = info(resources: resources)
        // Metadata-only drift: same resources, different modification date.
        let favorited = info(modified: Date(timeIntervalSince1970: 1_700_009_999), resources: resources)

        guard case .revision(let fpBase) = PhotoBackupAssetPlanner.editRevision(for: base),
            case .revision(let fpAfter) = PhotoBackupAssetPlanner.editRevision(for: favorited)
        else {
            return XCTFail("unedited assets must expose fingerprint evidence")
        }
        XCTAssertEqual(fpBase, fpAfter, "metadata-only changes must not move the fingerprint")
        XCTAssertNotEqual(
            fpBase, PhotoBackupAssetPlanner.metadataRevision(for: base),
            "fingerprint must be distinct from the metadata revision")
    }

    func testTheRenderedFileOfAnEditMovesTheRevisionWithoutADateChange() {
        let unrendered = edited(secondsAgo: 600, rendered: false)
        let rendered = edited(secondsAgo: 600)
        let unedited = edited(secondsAgo: 600, hasAdjustments: false, rendered: false)

        XCTAssertEqual(unrendered.modificationDate, rendered.modificationDate)
        XCTAssertLessThan(
            PhotoBackupAssetPlanner.metadataRevision(for: unrendered).rawValue,
            PhotoBackupAssetPlanner.metadataRevision(for: rendered).rawValue,
            "a backup that holds the original re-opens as a later revision when Photos lists the rendered file")
        XCTAssertEqual(
            PhotoBackupAssetPlanner.metadataRevision(for: rendered),
            PhotoBackupAssetPlanner.metadataRevision(for: unedited),
            "a photo without a missing rendered file keeps its date revision")
    }

    func testEditedAssetRefusesFingerprintTrust() {
        let edited = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: nil),
        ])
        XCTAssertEqual(
            PhotoBackupAssetPlanner.editRevision(for: edited), .unavailable,
            "edited assets must re-verify by hash - never trust a structural fingerprint")
    }

    func testFirstEditChangesTheFingerprint() {
        let before = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil)
        ])
        let after = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: nil),
        ])
        guard case .revision = PhotoBackupAssetPlanner.editRevision(for: before) else {
            return XCTFail("unedited baseline expected")
        }
        XCTAssertEqual(
            PhotoBackupAssetPlanner.editRevision(for: after), .unavailable,
            "the first edit adds adjustment resources and must invalidate fingerprint trust")
    }

    func testMetadataOnlyChangeClassifiesAlreadyBackedUpWithoutRecheck() async throws {
        final class MemoryStore: UploadBackupStateStore, @unchecked Sendable {
            private let lock = NSLock()
            private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]
            func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
                lock.withLock { rows[source]?[revision] }
            }
            func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
                lock.withLock { !(rows[source]?.isEmpty ?? true) }
            }
            func upsert(_ record: UploadBackupAssetRecord) -> Bool {
                lock.withLock { rows[record.source, default: [:]][record.revision] = record }
                return true
            }
            func count() -> Int { lock.withLock { rows.values.reduce(0) { $0 + $1.count } } }
        }

        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil)
        ]
        let original = info(resources: resources)
        let favorited = info(modified: Date(timeIntervalSince1970: 1_700_050_000), resources: resources)

        let index = UploadBackupPreflightIndex(store: MemoryStore())
        let originalSnapshot = PhotoBackupAssetPlanner.candidate(for: original)!.snapshot
        try await index.markBackedUp(originalSnapshot)

        let decision = try await index.classify(PhotoBackupAssetPlanner.candidate(for: favorited)!.snapshot)
        XCTAssertEqual(
            decision, .alreadyBackedUp,
            "a favorite toggle must not export, hash, or query anything")
    }

    func testAssetWithoutExportableResourceIsSkipped() {
        let broken = info(resources: [
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil)
        ])
        XCTAssertNil(PhotoBackupAssetPlanner.candidate(for: broken))
    }

    func testAccessStateBackupGating() {
        XCTAssertTrue(PhotoBackupAccessState.full.allowsBackup)
        XCTAssertTrue(PhotoBackupAccessState.limited.allowsBackup, "limited access backs up the selection honestly")
        XCTAssertFalse(PhotoBackupAccessState.denied.allowsBackup)
        XCTAssertFalse(PhotoBackupAccessState.notDetermined.allowsBackup)
        XCTAssertFalse(PhotoBackupAccessState.restricted.allowsBackup)
    }
}
