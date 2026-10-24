#if canImport(UIKit)
    import CoreGraphics
    import GridCore
    import MediaCacheUIKitAdapter
    import MetalGridTextureCore
    import PhotosCore
    import TimelineUIKitAdapter
    import UIKit

    /// The grid host's decode/warm pipeline: the feed's arrival wake, the visible warm pass, and the
    /// direction-biased scroll-ahead prefetch. The render loop schedules it only from settled frames.
    extension UIKitTimelineGridHostView {
        /// Arrival wake from the shared feed (a background download landed thumbnails on disk while this viewport is
        /// live). Re-warm still-missing visible cells from disk and request a redraw. The arrival wake lets the
        /// render loop remain idle during network waits.
        func handleImagesAvailable() {
            warmNeedsRepass = true
            requestRender()
        }

        func newestFirst(_ uids: [PhotoUID]) -> [PhotoUID] {
            uids.sorted { lhs, rhs in
                (itemIndexByUID[lhs] ?? -1) > (itemIndexByUID[rhs] ?? -1)
            }
        }

        /// The tiles of `uids` that are not resident and may still be fetched, newest first, and how many of them
        /// already have a decoded image in RAM.
        func missingRetryableTiles(
            in uids: [PhotoUID],
            isResident: (PhotoUID) -> Bool
        ) -> (uids: [PhotoUID], ramReady: Int) {
            let feed = thumbnailFeed
            let missing = newestFirst(
                uids.filter { uid in
                    !isResident(uid) && !(feed?.isKnownUnfetchable(uid) ?? false)
                })
            let ramReady = missing.reduce(into: 0) { count, uid in
                if feed?.memoryCGImage(for: uid) != nil { count += 1 }
            }
            return (missing, ramReady)
        }

        /// The still-missing visible tiles (newest-first, reliability-critical order) followed by any additional warm
        /// UIDs the composer requested (upgrade re-decode sources), de-duplicated. A no-op-ish superset when settled
        /// is off (the composer's warm list is then just the missing tiles).
        func warmUnion(_ missing: [PhotoUID], _ streamWarm: [PhotoUID]) -> [PhotoUID] {
            guard !streamWarm.isEmpty else { return missing }
            var out = missing
            var seen = Set(missing)
            for uid in streamWarm where seen.insert(uid).inserted { out.append(uid) }
            return out
        }

        /// Pre-decode the rows just beyond the streamed window in the user's travel direction, from disk to RAM, at
        /// `.nearViewportScrollAhead` priority - the shared `GridScrollAheadPolicy` range over this host's flat
        /// UID order. Strictly subordinate to visible work: it runs only on settled frames with no visible warm
        /// pass in flight, decodes in small chunks, and aborts between chunks the moment a visible pass starts.
        /// RAM-neutral by design: it fills the existing decoded budget ahead of need; no cache grows.
        func scheduleScrollAheadWarmIfIdle(plan: GridFramePlan) {
            // Never pre-warm ahead for an inactive or hidden grid; that would decode disk to RAM off-screen while the
            // user is in another tab/menu. (renderNow only runs when active, so this is defense-in-depth.)
            guard framePump.isActive else { return }
            guard let thumbnailFeed, let down = scrollDirectionDown, !itemUIDs.isEmpty else { return }
            guard !warmInFlight, !aheadWarmInFlight else { return }
            let indices = plan.visibleSlots.map(\.index)
            guard let minIndex = indices.min(), let maxIndex = indices.max() else { return }
            let range = GridScrollAheadPolicy.aheadRange(
                coveredIndexRange: minIndex...maxIndex,
                itemCount: itemUIDs.count,
                columns: plan.columns,
                rowsAhead: 3,
                direction: down ? .towardHigherIndices : .towardLowerIndices
            )
            guard !range.isEmpty else { return }
            let key = "\(range.lowerBound)-\(range.upperBound)-\(down)-\(plan.levelID)"
            guard key != lastAheadKey else { return }
            lastAheadKey = key
            let pixelSize = GridTextureUploadSizing.uploadPixels(
                slotSidePoints: plan.slotSide,
                backingScale: metalView.metalLayer.contentsScale,
                headroom: 1.15,
                floor: 64,
                cap: textureCache?.maxTexturePixels ?? 320
            )
            // Ahead tiles count as needing work when absent OR decoded materially below this level's pixels,
            // so scrolling after a zoom-in lands on rows that are already re-decoded sharp, not just present.
            let missing =
                range
                .map { itemUIDs[$0] }
                .filter { uid in
                    (thumbnailFeed.memoryCGImage(for: uid) == nil
                        || thumbnailFeed.decodedNeedsSharperSource(uid, forPixels: pixelSize))
                        && !thumbnailFeed.isKnownUnfetchable(uid)
                }
            guard !missing.isEmpty else { return }
            let requests = missing.map {
                ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue)
            }
            aheadWarmInFlight = true
            aheadWarmTask = Task { [weak self, thumbnailFeed] in
                // Small chunks so a visible warm pass (which takes strict priority) never waits behind a long
                // ahead batch on the serial feed actor; abort the remainder the moment visible work starts.
                for chunk in stride(from: 0, to: requests.count, by: 12).map({
                    Array(requests[$0..<min($0 + 12, requests.count)])
                }) {
                    if Task.isCancelled { break }
                    let visibleBusy = await MainActor.run { [weak self] in self?.warmInFlight ?? true }
                    if visibleBusy { break }
                    _ = await thumbnailFeed.warmDecoded(chunk, priority: .nearViewportScrollAhead, limit: chunk.count)
                }
                await MainActor.run { [weak self] in self?.aheadWarmInFlight = false }
            }
        }

        /// Decode still-missing visible cells from disk to RAM, queuing network work for the rest.
        ///
        /// The gate is `warmInFlight`, not exact-set equality. Re-issue a pass when the missing set changes or
        /// `warmNeedsRepass` is raised by a feed arrival or demand move. A static viewport can therefore decode
        /// newly-arrived disk bytes into the RAM tier. On completion it redraws;
        /// if cells are still missing the next frame re-invokes this, so the fill continues to convergence.
        func scheduleWarmIfNeeded(_ uids: [PhotoUID], pixelSize: Int) {
            guard let thumbnailFeed else { return }
            let unique = uniqueUIDs(uids)
            guard !unique.isEmpty else {
                // The viewport needs nothing more; loads it asked for earlier may stop.
                if !lastWarmIDs.isEmpty {
                    let feedCore = thumbnailFeed.feedCore
                    Task { await feedCore.clearLocalVisibleDemand() }
                }
                lastWarmIDs = []
                warmNeedsRepass = false
                return
            }
            if warmInFlight {
                // A pass is running; if demand moved, remember to re-issue once it finishes.
                if unique != lastWarmIDs { warmNeedsRepass = true }
                return
            }
            guard unique != lastWarmIDs || warmNeedsRepass else { return }
            warmNeedsRepass = false
            lastWarmIDs = unique
            warmInFlight = true
            warmGeneration &+= 1
            let generation = warmGeneration
            let requests = unique.map {
                ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue)
            }
            warmTask = Task { [weak self, thumbnailFeed] in
                _ = await thumbnailFeed.warmVisibleDecoded(requests, limit: max(1, requests.count))
                await MainActor.run {
                    guard let self, self.warmGeneration == generation else { return }
                    self.warmInFlight = false
                    // Redraw to upload whatever decoded; renderNow re-invokes this for any cells still missing.
                    self.requestRender()
                }
            }
        }
    }
#endif
