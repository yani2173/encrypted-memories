import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

/// The listing names the related files of a Live Photo newest first and without a type. An edited Live Photo names its
/// adjustment data, its edited motion, its paired video, and its original photo.
@Suite
struct LivePhotoMotionLinksTests {
    private let types = [
        "plist": "application/xml",
        "paired": "video/quicktime",
        "edited": "video/quicktime",
        "original": "image/heic",
        "other": "application/octet-stream",
        "motion": "video/quicktime",
    ]

    @Test
    func aLivePhotoWithOneRelatedFileTakesItAsMotionOnlyWhenItIsAVideo() async throws {
        #expect(LivePhotoMotionLinks.motion(among: [], mimeTypes: [:]) == .unknown)
        var reads: [[String]] = []
        let answer = try await LivePhotoMotionLinks().motions(
            of: ["video": ["motion"], "edited": ["plist"], "none": []], stored: [:], evidence: [:]
        ) { linkIDs in
            reads.append(linkIDs)
            return types
        }
        #expect(reads == [["plist", "motion"]], "one read, also for a single related file")
        #expect(answer.motions == ["video": .video("motion"), "edited": .noVideo, "none": .unknown])
        #expect(!LivePhotoMotion.noVideo.showsLiveControl, "only adjustment data: no Live control")
        #expect(LivePhotoMotion.video("motion").showsLiveControl)
    }

    @Test
    func anEditedLivePhotoPlaysItsFirstVideoInsteadOfItsNewestRelatedFile() {
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "paired", "edited", "original"], mimeTypes: types)
                == .video("paired"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["other", "plist", "paired", "original"], mimeTypes: types)
                == .video("paired"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "other", "original"], mimeTypes: types) == .noVideo,
            "a Live Photo without a video has no motion")
    }

    @Test
    func anUnknownTypeBeforeTheFirstVideoLeavesTheMotionUnknown() {
        #expect(LivePhotoMotionLinks.motion(among: ["plist", "unknown", "paired"], mimeTypes: types) == .unknown)
    }

    @Test
    func readsOnlyTheUnknownRelatedFilesOfLivePhotosOnce() async throws {
        var links = LivePhotoMotionLinks()
        let photos = ["a": ["motion"], "b": ["plist", "paired"], "c": ["paired", "edited", "plist"]]
        let evidence = ["plist": "application/xml"]
        var reads: [[String]] = []

        let first = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs in
            reads.append(linkIDs)
            return ["motion": "video/quicktime", "paired": "video/quicktime", "plist": "text/plain"]
        }
        links.record(first.read)
        #expect(reads == [["motion", "paired", "edited"]])
        #expect(first.complete)
        #expect(first.read == ["motion": "video/quicktime", "paired": "video/quicktime", "edited": ""])
        #expect(first.motions == ["a": .video("motion"), "b": .video("paired"), "c": .video("paired")])

        let second = try await links.motions(of: photos, stored: [:], evidence: evidence) { linkIDs in
            reads.append(linkIDs)
            return [:]
        }
        #expect(reads.count == 1, "a read type stays valid for the session")
        #expect(second.motions == first.motions)
    }

    @Test
    func aFailedReadLeavesTheMotionUnknownAndReadsAgainNextTime() async throws {
        struct Offline: Error {}
        var links = LivePhotoMotionLinks()
        let photos = ["live": ["plist", "paired"]]

        let failed = try await links.motions(of: photos, stored: [:], evidence: [:]) { _ in throw Offline() }
        links.record(failed.read)
        #expect(!failed.complete)
        #expect(failed.read.isEmpty)
        #expect(failed.motions == ["live": .unknown])

        var reads = 0
        let retried = try await links.motions(of: photos, stored: [:], evidence: [:]) { _ in
            reads += 1
            return types
        }
        #expect(reads == 1)
        #expect(retried.complete)
        #expect(retried.motions == ["live": .video("paired")])

        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks().motions(of: photos, stored: [:], evidence: [:]) { _ in
                throw CancellationError()
            }
        }
    }

    @Test
    func aLaterLaunchReadsNothingForUnchangedLivePhotosAndReadsAChangedOneAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var photos = [
            "one": ["plist-1", "paired-1", "original-1"], "three": ["paired-3"], "two": ["other-2", "paired-2"],
        ]

        // An earlier build stored the first related file as the motion and never marked its rule.
        var store = try #require(TimelineMetadataStore(url: url))
        #expect(store.save(items(photos.mapValues { $0[0] })).succeeded)
        let first = try await launch(photos, store: store)
        #expect(
            first.reads == ["plist-1", "paired-1", "original-1", "paired-3", "other-2", "paired-2"],
            "rows before the mark, also of a Live Photo with one related file")
        #expect(first.motions == ["one": .video("paired-1"), "three": .video("paired-3"), "two": .video("paired-2")])
        #expect(store.save(items(first.motions.compactMapValues(\.linkID))).succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        store.close()

        store = try #require(TimelineMetadataStore(url: url))
        let second = try await launch(photos, store: store)
        #expect(second.reads.isEmpty, "unchanged Live Photos read nothing on a later launch")
        #expect(second.motions == first.motions)

        // A changed related list without the stored video reads again, for that photo only.
        photos["two"] = ["other-2", "edited-2"]
        let third = try await launch(photos, store: store)
        #expect(third.reads == ["other-2", "edited-2"])
        #expect(third.motions == ["one": .video("paired-1"), "three": .video("paired-3"), "two": .video("edited-2")])

        // A later save that does not mark the rule, for example by an earlier build, voids the mark.
        #expect(store.save(items(["one": "plist-1", "three": "paired-3", "two": "other-2"])).succeeded)
        #expect(try await launch(photos, store: store).reads.count == 6)
        store.close()
    }

    @Test
    func aFailedReadStillCommitsTheTimelineAndTheNextRefreshReadsOnlyThosePhotos() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        defer { store.close() }
        let photos = ["known": ["paired-1"], "failed": ["plist-2", "paired-2"]]

        // The read of "failed" fails: its motion stays unknown, and the timeline and its token are still saved.
        let motions = try await LivePhotoMotionLinks().motions(
            of: photos, stored: ["known": "paired-1"], evidence: [:]
        ) { _ in throw URLError(.timedOut) }
        #expect(motions.motions == ["known": .video("paired-1"), "failed": .unknown])
        let saved = photos.keys.sorted().enumerated().map { index, linkID in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: linkID), captureTime: Date(timeIntervalSince1970: Double(index)),
                mediaType: "image/heic", isLivePhoto: motions.motions[linkID]!.showsLiveControl,
                relatedVideoID: motions.motions[linkID]?.linkID)
        }
        #expect(store.save(saved, validationToken: "token").succeeded)
        #expect(store.markRelatedVideosChosen(by: LivePhotoMotionLinks.rule))
        #expect(store.validationToken() == "token")

        #expect(try await launch(photos, store: store).reads == ["plist-2", "paired-2"])
    }

    /// One refresh of a new session: the stored motions, then one read of the files that still need a type.
    private func launch(
        _ photos: [String: [String]], store: TimelineMetadataStore
    ) async throws -> (motions: [String: LivePhotoMotion], reads: [String]) {
        var reads: [String] = []
        let stored = LivePhotoMotionLinks.storedMotions(of: photos, volumeID: "v", in: store)
        let answer = try await LivePhotoMotionLinks().motions(of: photos, stored: stored, evidence: [:]) { linkIDs in
            reads += linkIDs
            return Dictionary(
                uniqueKeysWithValues: linkIDs.map {
                    ($0, $0.hasPrefix("paired") || $0.hasPrefix("edited") ? "video/quicktime" : "image/heic")
                })
        }
        return (answer.motions, reads)
    }

    private func items(_ motions: [String: String]) -> [PhotoItem] {
        motions.keys.sorted().enumerated().map { index, linkID in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: linkID), captureTime: Date(timeIntervalSince1970: Double(index)),
                mediaType: "image/heic", isLivePhoto: true, relatedVideoID: motions[linkID])
        }
    }

    @Test
    func metadataBatchesRunAFewAtATimeAndKeepTheirOrder() async throws {
        let linkIDs = (0..<1_000).map { "link-\($0)" }
        let gauge = InFlightGauge()
        let answers = try await DriveSDKBridge.concurrentMetadataBatches(linkIDs) { batch in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            return batch
        }
        #expect(answers.count == 7)
        #expect(answers.allSatisfy { $0.count <= 150 })
        #expect(answers.flatMap { $0 } == linkIDs)
        let peak = await gauge.peak
        #expect(peak <= ProtonUploadDedupeService.remoteMetadataRequestConcurrency)
        #expect(peak > 1, "the batches overlap")
    }

    @Test
    func theTimelineShowsTheVideoAsTheMotionAndNoLiveControlWithoutAVideo() async throws {
        let live = PhotosCore.PhotoTag.livePhotos.rawValue
        let entries = try JSONDecoder().decode(
            [PhotosListEntry].self,
            from: Data(
                #"""
                [{"LinkID":"live","CaptureTime":1,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"paired"},{"LinkID":"original"}]},
                {"LinkID":"novideo","CaptureTime":2,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"original"}]},
                {"LinkID":"single","CaptureTime":3,"Tags":[3],"RelatedPhotos":[{"LinkID":"motion"}]},
                {"LinkID":"unread","CaptureTime":4,"Tags":[3],"RelatedPhotos":[{"LinkID":"x"},{"LinkID":"y"}]},
                {"LinkID":"adjusted","CaptureTime":5,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"}]}]
                """#
                .utf8))
        #expect(entries.allSatisfy { $0.tags == [live] })

        let motions = try await LivePhotoMotionLinks().motions(
            of: [
                "live": ["plist", "paired", "original"], "novideo": ["plist", "original"], "single": ["motion"],
                "unread": ["x", "y"], "adjusted": ["plist"],
            ],
            stored: [:], evidence: types
        ) { _ in throw URLError(.notConnectedToInternet) }
        let items = DriveSDKBridge.group(entries, volumeID: "v", motions: motions.motions).flatMap(\.items)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.uid.nodeID, $0) })

        #expect(byID["live"]?.isLivePhoto == true)
        #expect(byID["live"]?.relatedVideoID == "paired")
        #expect(byID["novideo"]?.isLivePhoto == false)
        #expect(byID["novideo"]?.relatedVideoID == nil)
        #expect(byID["single"]?.relatedVideoID == "motion")
        #expect(byID["unread"]?.isLivePhoto == true, "an unread type keeps the Live tag without a motion")
        #expect(byID["unread"]?.relatedVideoID == nil)
        #expect(byID["adjusted"]?.isLivePhoto == false, "only adjustment data: no Live control")
        #expect(byID["adjusted"]?.relatedVideoID == nil)

        // The SDK timeline shows every Live Photo like the photos listing, an unknown motion included.
        let sdkItems = DriveSDKBridge.group(
            entries.map {
                PhotoTimelineItem(nodeUid: SDKNodeUid(volumeID: "v", nodeID: $0.linkID), captureTime: $0.captureTime)
            },
            livePhotoMotions: motions.motions
        ).flatMap(\.items)
        #expect(sdkItems.map(\.uid) == items.map(\.uid))
        #expect(sdkItems.map(\.isLivePhoto) == items.map(\.isLivePhoto))
        #expect(sdkItems.map(\.relatedVideoID) == items.map(\.relatedVideoID))
    }
}

private actor InFlightGauge {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}
