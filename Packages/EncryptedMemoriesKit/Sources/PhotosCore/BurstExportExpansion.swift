import Foundation

/// Decides, once and for every host, which photos an export request carries after expanding
/// Proton burst/series selections.
///
/// The hosts pass their backend's burst-group lookup as a closure and present the returned
/// result; they never interpret burst semantics themselves. A burst candidate whose group read
/// throws, or answers without the members the photo declares, is an export failure, not a silent
/// single-photo export.
public enum BurstExportExpansion {
    /// The expansion outcome of one export request.
    public enum Result: Equatable, Sendable {
        /// The deduplicated items to export, and whether a single burst series was expanded
        /// (which names the ZIP after that series instead of the generic container).
        case success(items: [PhotoItem], expandedSingleSeries: Bool)
        /// At least one burst candidate's group read threw or answered without its declared
        /// members; nothing must be exported.
        case burstReadFailed(failedSources: [PhotoItem])
        /// The viewer's knowledge about the shown burst is still being read; nothing
        /// must be exported yet, and no failure happened. The viewer waits for the read.
        /// Only `BurstSelectionModel.viewerExportDecision` returns it; `expand` never does.
        case burstLoading
        /// A read ended as a cancellation (`LibraryActionFailureMessage.isCancellation`);
        /// nothing was exported and no failure happened, so the host shows no alert.
        case cancelled
    }

    /// Expands the source items of an export request.
    ///
    /// `preferredSeriesNameSource` is the single tapped item a viewer export names the archive
    /// after. A multi-item selection that already contains the whole known series of that item
    /// takes the fast path and performs no backend reads.
    public static func expand(
        sourceItems: [PhotoItem],
        preferredSeriesNameSource: PhotoItem?,
        burstGroupReader: @escaping @Sendable (PhotoUID) async throws -> [PhotoItem]
    ) async -> Result {
        var expanded: [PhotoItem] = []
        var seen = Set<PhotoUID>()
        var expandedSingleSeries = false
        var failedSources: [PhotoItem] = []

        func appendUnique(_ item: PhotoItem) {
            guard seen.insert(item.uid).inserted else { return }
            expanded.append(item)
        }

        let memberIDSet = Set(
            (preferredSeriesNameSource?.burstMemberIDs ?? []).map {
                PhotoUID(volumeID: preferredSeriesNameSource?.uid.volumeID ?? "", nodeID: $0)
            })
        let sourceUIDSet = Set(sourceItems.map(\.uid))
        let alreadyExpandedPreferredSeries =
            sourceItems.count > 1
            && preferredSeriesNameSource?.isBurstCandidate == true
            && !memberIDSet.isEmpty
            && sourceUIDSet.isSubset(of: memberIDSet)

        if alreadyExpandedPreferredSeries {
            sourceItems.forEach(appendUnique)
            expandedSingleSeries = true
        } else {
            for item in sourceItems {
                guard item.isBurstCandidate else {
                    appendUnique(item)
                    continue
                }
                let group: [PhotoItem]
                do {
                    group = try await burstGroupReader(item.uid)
                } catch {
                    // The export failure alert uses the same classification, so a cancel that
                    // stays quiet there stays quiet here.
                    if LibraryActionFailureMessage.isCancellation(error) {
                        return .cancelled
                    }
                    failedSources.append(item)
                    continue
                }
                if group.count > 1 {
                    group.forEach(appendUnique)
                    expandedSingleSeries = true
                } else if answerMissesDeclaredMembers(group, of: item) {
                    failedSources.append(item)
                } else {
                    appendUnique(item)
                }
            }
        }

        if !failedSources.isEmpty {
            return .burstReadFailed(failedSources: failedSources)
        }
        return .success(items: expanded, expandedSingleSeries: expandedSingleSeries)
    }

    /// True when a group read answered with fewer than two photos for a photo that declares two or
    /// more members. The answer then contradicts the photo, so the read did not load the burst.
    ///
    /// One answer is not a contradiction: the photo itself, naming only itself as a frame
    /// (`BurstGroupProvider`). Its other members are then related files that are no frames, such as
    /// the adjustment data of an edit. A photo that only carries the burst tag declares no members
    /// and keeps its single-photo export.
    public static func answerMissesDeclaredMembers(_ group: [PhotoItem], of item: PhotoItem) -> Bool {
        guard group.count < 2 else { return false }
        if let lone = group.first, lone.uid == item.uid, lone.burstMemberIDs == [item.uid.nodeID] {
            return false
        }
        return item.burstMemberIDs.count > 1
    }
}
