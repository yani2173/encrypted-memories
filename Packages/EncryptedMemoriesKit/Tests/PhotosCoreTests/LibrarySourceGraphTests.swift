import XCTest

@testable import PhotosCore

final class LibrarySourceGraphTests: XCTestCase {
    private let firstSource = LibrarySource(
        id: SourceID("first"),
        capabilities: [.readMetadata, .readThumbnail, .readContent],
        precedence: 10
    )
    private let secondSource = LibrarySource(
        id: SourceID("second"),
        capabilities: [.readMetadata, .readThumbnail, .readContent],
        precedence: 5
    )

    private func item(
        _ nodeID: String,
        time: TimeInterval,
        mediaType: String = "image/jpeg",
        isLivePhoto: Bool = false,
        relatedVideoID: String? = nil,
        duration: Double? = nil,
        tags: Set<PhotoTag> = [],
        burstMemberIDs: [String] = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: nodeID),
            captureTime: Date(timeIntervalSince1970: time),
            mediaType: mediaType,
            isLivePhoto: isLivePhoto,
            relatedVideoID: relatedVideoID,
            durationSeconds: duration,
            tags: tags,
            burstMemberIDs: burstMemberIDs
        )
    }

    private func install(
        _ source: LibrarySource,
        items: [PhotoItem],
        in graph: inout LibrarySourceGraph
    ) -> LibrarySourceChange {
        var sources = graph.inventories()
            .filter { $0.accessState != .accessLost }
            .map(\.source)
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet(sources, using: sourceSetLease)
        let lease = try! XCTUnwrap(graph.beginRefresh(source.id))
        return try! XCTUnwrap(
            graph.commit(items.map(LibrarySourceItem.complete), validationToken: nil, using: lease)
        )
    }

    func testTimelineOrderEvidenceSurvivesSourceProjectionAndMerge() throws {
        var earlier = item("z-earlier", time: 500)
        earlier.timelineOrder = .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1))
        var edited = item("0-edited", time: 500)
        edited.timelineOrder = .init(exactCaptureTime: Date(timeIntervalSince1970: 500.8))
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [edited, earlier], in: &graph)
        XCTAssertEqual(graph.selectedProjection().timeline.uids, [earlier.uid, edited.uid])
        XCTAssertEqual(
            graph.selectedProjection().timeline.snapshot.item(for: edited.uid)?.timelineOrder, edited.timelineOrder)

        // An overlapping source without order evidence must not erase the refined primary capture order.
        _ = install(secondSource, items: [item("0-edited", time: 500), item("z-earlier", time: 500)], in: &graph)
        XCTAssertEqual(graph.selectedProjection().timeline.uids, [earlier.uid, edited.uid])
        XCTAssertEqual(
            graph.selectedProjection().timeline.snapshot.item(for: edited.uid)?.timelineOrder, edited.timelineOrder)

        var fallbackGraph = LibrarySourceGraph()
        _ = install(
            firstSource, items: [item("0-edited", time: 500), item("z-earlier", time: 500)], in: &fallbackGraph)
        _ = install(secondSource, items: [edited, earlier], in: &fallbackGraph)
        XCTAssertEqual(fallbackGraph.selectedProjection().timeline.uids, [earlier.uid, edited.uid])
    }

    func testRenewalAfterAMetadataRefreshKeepsTheRouteAndTheSource() throws {
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [item("photo", time: 1)], in: &graph)
        let uid = item("photo", time: 1).uid
        let lease = try XCTUnwrap(graph.accessLease(for: uid, requiring: .readThumbnail))

        _ = install(firstSource, items: [item("photo", time: 1, tags: [.favorites])], in: &graph)

        XCTAssertFalse(graph.isCurrent(lease), "every changed item invalidates the leases of its source")
        let renewed = try XCTUnwrap(graph.renewed(lease))
        XCTAssertEqual(renewed.sourceID, firstSource.id)
        XCTAssertTrue(graph.isCurrent(renewed))
    }

    func testRenewalFailsWhenThePhotoLeftOrTheSourceLostAccess() throws {
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [item("photo", time: 1)], in: &graph)
        let uid = item("photo", time: 1).uid
        let lease = try XCTUnwrap(graph.accessLease(for: uid, requiring: .readThumbnail))

        _ = install(firstSource, items: [], in: &graph)
        XCTAssertNil(graph.renewed(lease))

        _ = install(firstSource, items: [item("photo", time: 1)], in: &graph)
        let readded = try XCTUnwrap(graph.accessLease(for: uid, requiring: .readThumbnail))
        _ = graph.removeSource(firstSource.id)
        XCTAssertNil(graph.renewed(readded))
    }

    func testRenewalNeverMovesALeaseToAnotherSource() throws {
        var graph = LibrarySourceGraph()
        let shared = item("shared", time: 1)
        _ = install(firstSource, items: [shared], in: &graph)
        _ = install(secondSource, items: [shared], in: &graph)
        let lease = try XCTUnwrap(graph.accessLease(for: shared.uid, requiring: .readThumbnail))

        // The source that issued the lease drops the photo; another source still lists it.
        let otherID = lease.sourceID == firstSource.id ? secondSource : firstSource
        let issuing = lease.sourceID == firstSource.id ? firstSource : secondSource
        _ = install(issuing, items: [], in: &graph)

        XCTAssertEqual(graph.accessLease(for: shared.uid, requiring: .readThumbnail)?.sourceID, otherID.id)
        XCTAssertNil(graph.renewed(lease), "a renewal keeps the route of the original lease")
    }

    func testRenewalReturnsNothingWhenAHigherSourceNowServesThePhoto() throws {
        var graph = LibrarySourceGraph()
        let shared = item("shared", time: 1)
        _ = install(secondSource, items: [shared], in: &graph)
        let lease = try XCTUnwrap(graph.accessLease(for: shared.uid, requiring: .readThumbnail))
        XCTAssertEqual(lease.sourceID, secondSource.id)

        _ = install(firstSource, items: [shared], in: &graph)

        XCTAssertEqual(graph.accessLease(for: shared.uid, requiring: .readThumbnail)?.sourceID, firstSource.id)
        XCTAssertNil(graph.renewed(lease), "the caller withholds the bytes and requests them again")
    }

    func testRenewalAuthorizesByTheCurrentStateAfterReactivation() throws {
        var graph = LibrarySourceGraph()
        let photo = item("photo", time: 1)
        _ = install(firstSource, items: [photo], in: &graph)
        let lease = try XCTUnwrap(graph.accessLease(for: photo.uid, requiring: .readThumbnail))

        _ = graph.removeSource(firstSource.id)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .accessLost)
        XCTAssertNil(graph.renewed(lease))

        // Access returns and the source lists the photo again: the graph authorizes the same route now.
        _ = install(firstSource, items: [photo], in: &graph)
        XCTAssertNotNil(graph.renewed(lease))
    }

    func testRenewalOfASeriesMemberRequiresTheSameSeries() throws {
        var graph = LibrarySourceGraph()
        let member = item("member", time: 3)
        _ = install(firstSource, items: [item("key", time: 1, burstMemberIDs: ["key", "member"])], in: &graph)
        let lease = try XCTUnwrap(
            graph.burstMemberAccessLeases(for: [member.uid], requiring: .readThumbnail)[member.uid])

        _ = install(
            firstSource, items: [item("key", time: 1, tags: [.favorites], burstMemberIDs: ["key", "member"])],
            in: &graph)
        XCTAssertNotNil(graph.renewed(lease), "a refreshed series still lists its member")

        _ = install(
            firstSource,
            items: [
                item("key", time: 1, burstMemberIDs: ["key"]),
                item("other", time: 2, burstMemberIDs: ["other", "member"]),
            ],
            in: &graph)
        XCTAssertNotNil(graph.burstMemberAccessLeases(for: [member.uid], requiring: .readThumbnail)[member.uid])
        XCTAssertNil(graph.renewed(lease), "another series lists the member now; a fresh request must prove it")
    }

    func testRenewalRejectsALeaseOfAnotherGraph() throws {
        var first = LibrarySourceGraph()
        var second = LibrarySourceGraph()
        _ = install(firstSource, items: [item("photo", time: 1)], in: &first)
        _ = install(firstSource, items: [item("photo", time: 1)], in: &second)
        let lease = try XCTUnwrap(first.accessLease(for: item("photo", time: 1).uid, requiring: .readThumbnail))

        XCTAssertNil(second.renewed(lease), "a lease never crosses an account or session")
    }

    func testProjectionDeduplicatesResourceIdentityAndKeepsEveryMembership() throws {
        let duplicate = item("same", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [duplicate, item("first-only", time: 20)], in: &graph)
        _ = install(secondSource, items: [duplicate, item("second-only", time: 30)], in: &graph)

        let projection = graph.selectedProjection()

        XCTAssertEqual(projection.timeline.uids.map(\.nodeID), ["same", "first-only", "second-only"])
        XCTAssertEqual(projection.sourceIDs(for: duplicate.uid), [firstSource.id, secondSource.id])
        XCTAssertEqual(projection.timeline.snapshot.count, 3)
    }

    func testHigherPrecedenceCompleteMetadataWinsWithoutCrossSourceTagLeakage() throws {
        let preferred = item(
            "same",
            time: 10,
            mediaType: "image/heic",
            isLivePhoto: true,
            relatedVideoID: "motion",
            tags: [.favorites],
            burstMemberIDs: ["a", "b"]
        )
        let fallback = item(
            "same",
            time: 99,
            mediaType: "video/quicktime",
            isLivePhoto: true,
            relatedVideoID: "fallback-motion",
            duration: 4,
            tags: [.videos],
            burstMemberIDs: ["b", "c"]
        )
        var graph = LibrarySourceGraph()
        _ = install(secondSource, items: [fallback], in: &graph)
        _ = install(firstSource, items: [preferred], in: &graph)

        let merged = try XCTUnwrap(graph.selectedProjection().timeline.snapshot.item(for: preferred.uid))

        XCTAssertEqual(merged.captureTime, preferred.captureTime)
        XCTAssertEqual(merged.mediaType, "image/heic")
        XCTAssertTrue(merged.isLivePhoto)
        XCTAssertEqual(merged.relatedVideoID, "motion")
        XCTAssertNil(merged.durationSeconds)
        XCTAssertEqual(merged.tags, [.favorites])
        XCTAssertEqual(merged.burstMemberIDs, ["a", "b"])
    }

    func testKnownLowerPrecedenceFieldsFillOnlyExplicitlyUnknownMetadata() throws {
        let preferred = item(
            "same",
            time: 10,
            mediaType: "image/heic",
            tags: [.favorites]
        )
        let fallback = item(
            "same",
            time: 99,
            mediaType: "video/quicktime",
            isLivePhoto: true,
            relatedVideoID: "motion",
            duration: 4,
            tags: [.videos],
            burstMemberIDs: ["a", "b"]
        )
        var graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource, secondSource], using: sourceSetLease))
        let preferredLease = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(
            graph.commit(
                [
                    LibrarySourceItem(
                        item: preferred,
                        knownFields: [.captureTime, .mediaType]
                    )
                ],
                validationToken: nil,
                using: preferredLease
            )
        )
        let fallbackLease = try XCTUnwrap(graph.beginRefresh(secondSource.id))
        _ = try XCTUnwrap(
            graph.commit([.complete(fallback)], validationToken: nil, using: fallbackLease)
        )

        let projection = graph.selectedProjection()
        let merged = try XCTUnwrap(projection.timeline.snapshot.item(for: preferred.uid))
        let metadata = try XCTUnwrap(projection.metadata(for: preferred.uid))

        XCTAssertEqual(merged.captureTime, preferred.captureTime)
        XCTAssertEqual(merged.mediaType, preferred.mediaType)
        XCTAssertTrue(merged.isLivePhoto)
        XCTAssertEqual(merged.relatedVideoID, "motion")
        XCTAssertEqual(merged.durationSeconds, 4)
        XCTAssertEqual(merged.tags, [.videos])
        XCTAssertEqual(merged.burstMemberIDs, ["a", "b"])
        XCTAssertEqual(metadata.knownFields, .complete)
    }

    func testRemovingOneMembershipKeepsResourceReachableUntilLastSourceIsRemoved() throws {
        let duplicate = item("same", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [duplicate], in: &graph)
        _ = install(secondSource, items: [duplicate], in: &graph)

        let firstRemoval = try XCTUnwrap(graph.removeSource(firstSource.id))

        XCTAssertTrue(firstRemoval.orphanedUIDs.isEmpty)
        XCTAssertEqual(firstRemoval.retentionScope.uids, [duplicate.uid])
        XCTAssertEqual(firstRemoval.selectedProjection.sourceIDs(for: duplicate.uid), [secondSource.id])

        let finalRemoval = try XCTUnwrap(graph.removeSource(secondSource.id))

        XCTAssertEqual(finalRemoval.orphanedUIDs, [duplicate.uid])
        XCTAssertTrue(finalRemoval.retentionScope.uids.isEmpty)
    }

    func testAccessLossInvalidatesLeaseAndLateCommitCannotResurrectContent() throws {
        let original = item("original", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [original], in: &graph)
        let staleLease = try XCTUnwrap(graph.beginRefresh(firstSource.id))

        let removal = try XCTUnwrap(graph.removeSource(firstSource.id))

        XCTAssertEqual(removal.orphanedUIDs, [original.uid])
        XCTAssertNil(
            graph.commit(
                [.complete(item("late", time: 20))],
                validationToken: "late",
                using: staleLease
            )
        )
        XCTAssertTrue(graph.retentionProjection().timeline.snapshot.isEmpty)
    }

    func testTransientFailureRetainsCachedInventoryButDefersDestructiveReconciliation() throws {
        let cached = item("cached", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [cached], in: &graph)
        let lease = try XCTUnwrap(graph.beginRefresh(firstSource.id))

        let change = try XCTUnwrap(graph.failRefresh(using: lease))

        XCTAssertEqual(change.selectedProjection.timeline.uids, [cached.uid])
        XCTAssertEqual(change.selectedScope.uids, [cached.uid])
        XCTAssertFalse(change.selectedScope.isAuthoritative)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .temporarilyUnavailable)
    }

    func testInclusionOnlyChangesSelectedScopeAndNeverGlobalRetention() throws {
        let retained = item("retained", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [retained], in: &graph)

        let change = try XCTUnwrap(graph.setIncluded(false, for: firstSource.id))

        XCTAssertTrue(change.selectedScope.uids.isEmpty)
        XCTAssertTrue(change.selectedScope.isAuthoritative)
        XCTAssertEqual(change.retentionScope.uids, [retained.uid])
        XCTAssertTrue(change.orphanedUIDs.isEmpty)
    }

    func testCatalogCommitCannotOverwriteConcurrentInclusionPreference() throws {
        let retained = item("retained", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [retained], in: &graph)
        let catalogLease = graph.beginSourceSetRefresh()

        _ = try XCTUnwrap(graph.setIncluded(false, for: firstSource.id))
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: catalogLease))

        XCTAssertEqual(graph.inventory(for: firstSource.id)?.source.isIncluded, false)
        XCTAssertTrue(graph.selectedProjection().timeline.snapshot.isEmpty)
        XCTAssertEqual(graph.retentionProjection().timeline.uids, [retained.uid])
    }

    func testCapabilityRoutingUsesHighestPrecedenceEligibleMembership() throws {
        let duplicate = item("same", time: 10)
        let writableFallback = LibrarySource(
            id: secondSource.id,
            capabilities: secondSource.capabilities.union(.writeContent),
            precedence: secondSource.precedence
        )
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [duplicate], in: &graph)
        _ = install(writableFallback, items: [duplicate], in: &graph)

        let projection = graph.selectedProjection()

        XCTAssertEqual(projection.preferredSourceID(for: duplicate.uid, requiring: .readContent), firstSource.id)
        XCTAssertEqual(projection.preferredSourceID(for: duplicate.uid, requiring: .writeContent), secondSource.id)
        XCTAssertNil(projection.preferredSourceID(for: duplicate.uid, requiring: .removeSource))
    }

    func testProjectionOrderIsCanonicalRegardlessOfSourceRegistrationOrder() throws {
        let earlier = item("z", time: 1)
        let tieLow = item("a", time: 2)
        let tieHigh = item("b", time: 2)

        var one = LibrarySourceGraph()
        _ = install(firstSource, items: [tieHigh], in: &one)
        _ = install(secondSource, items: [tieLow, earlier], in: &one)

        var two = LibrarySourceGraph()
        _ = install(secondSource, items: [earlier, tieLow], in: &two)
        _ = install(firstSource, items: [tieHigh], in: &two)

        XCTAssertEqual(one.selectedProjection().timeline.snapshot, two.selectedProjection().timeline.snapshot)
        XCTAssertEqual(one.selectedProjection().timeline.uids.map(\.nodeID), ["z", "a", "b"])
        XCTAssertEqual(one.selectedDerivedDataScope().orderedUIDs.map(\.nodeID), ["z", "a", "b"])
        XCTAssertEqual(
            one.selectedDerivedDataScope().orderedUIDs,
            two.selectedDerivedDataScope().orderedUIDs
        )
        XCTAssertEqual(
            one.selectedDerivedDataScope().isAuthoritative,
            two.selectedDerivedDataScope().isAuthoritative
        )
    }

    func testAuthoritativeRefreshRemovesOnlyThatSourcesMemberships() throws {
        let shared = item("shared", time: 10)
        let removedFromFirst = item("first-only", time: 20)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [shared, removedFromFirst], in: &graph)
        _ = install(secondSource, items: [shared], in: &graph)
        let lease = try XCTUnwrap(graph.beginRefresh(firstSource.id))

        let change = try XCTUnwrap(graph.commit([], validationToken: "next", using: lease))

        XCTAssertEqual(change.orphanedUIDs, [removedFromFirst.uid])
        XCTAssertEqual(change.retentionScope.uids, [shared.uid])
        XCTAssertEqual(change.selectedProjection.sourceIDs(for: shared.uid), [secondSource.id])
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.validationToken, "next")
    }

    func testDerivedDataScopeDeltaDeletesOnlyFromAnAuthoritativeReplacement() throws {
        let a = item("a", time: 1)
        let b = item("b", time: 2)
        var graph = LibrarySourceGraph()
        let first = install(firstSource, items: [a, b], in: &graph).selectedScope
        let refresh = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        let unavailable = try XCTUnwrap(graph.failRefresh(using: refresh)).selectedScope

        XCTAssertEqual(unavailable.delta(from: first).removedUIDs, [])
        XCTAssertFalse(unavailable.delta(from: first).allowsDestructiveReconciliation)

        let retry = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        let replacement = try XCTUnwrap(
            graph.commit([.complete(a)], validationToken: nil, using: retry)
        ).selectedScope
        let delta = replacement.delta(from: first)

        XCTAssertEqual(delta.removedUIDs, [b.uid])
        XCTAssertTrue(delta.allowsDestructiveReconciliation)
    }

    func testDerivedDataScopeDeltaDoesNotExposeUnprovenOrStaleRemovals() throws {
        let a = item("a", time: 1)
        let b = item("b", time: 2)
        var graph = LibrarySourceGraph()
        let previous = install(firstSource, items: [a, b], in: &graph).selectedScope
        _ = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        let partial = graph.selectedDerivedDataScope()

        XCTAssertEqual(partial.delta(from: previous).removedUIDs, [])
        XCTAssertFalse(partial.delta(from: previous).allowsDestructiveReconciliation)
        XCTAssertEqual(previous.delta(from: partial).addedUIDs, [])
        XCTAssertEqual(previous.delta(from: partial).removedUIDs, [])
        XCTAssertFalse(previous.delta(from: partial).allowsDestructiveReconciliation)
    }

    func testPersistedCachedInventoryRestoresContentWithoutClaimingAuthority() throws {
        let cached = LibrarySourceInventory(
            source: firstSource,
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [.complete(item("cached", time: 10))],
            validationToken: "token"
        )
        let data = try JSONEncoder().encode(cached)
        let restored = try JSONDecoder().decode(LibrarySourceInventory.self, from: data)
        let graph = try LibrarySourceGraph(restoring: [restored])

        XCTAssertEqual(graph.selectedProjection().timeline.uids.map(\.nodeID), ["cached"])
        XCTAssertFalse(graph.selectedDerivedDataScope().isAuthoritative)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.validationToken, "token")
    }

    func testPersistedAuthoritativeInventoryIsDowngradedUntilCurrentRefresh() throws {
        let restored = LibrarySourceInventory(
            source: firstSource,
            accessState: .available,
            authority: .authoritative,
            items: [.complete(item("stale-authority", time: 10))]
        )
        let graph = try LibrarySourceGraph(restoring: [restored])

        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .temporarilyUnavailable)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.authority, .cached)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)
    }

    func testEmptyUndiscoveredGraphCannotAuthorizeGlobalDeletion() {
        let graph = LibrarySourceGraph()

        XCTAssertTrue(graph.retentionDerivedDataScope().uids.isEmpty)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)
    }

    func testCachedEmptyInventoryCannotAuthorizeDeletionAfterSourceDiscovery() throws {
        var graph = LibrarySourceGraph()
        let sourceSet = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: sourceSet))

        _ = graph.installCachedInventory([], for: firstSource.id)

        XCTAssertTrue(graph.retentionDerivedDataScope().uids.isEmpty)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)

        let authoritativeRefresh = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        let accepted = try XCTUnwrap(
            graph.commit([], validationToken: nil, using: authoritativeRefresh)
        )
        XCTAssertTrue(accepted.retentionScope.uids.isEmpty)
        XCTAssertTrue(accepted.retentionScope.isAuthoritative)
    }

    func testFailedSourceSetRefreshRestoresPriorAuthority() throws {
        let retained = item("retained", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [retained], in: &graph)
        XCTAssertEqual(graph.sourceSetAuthority, .authoritative)
        XCTAssertTrue(graph.retentionDerivedDataScope().isAuthoritative)

        let failedRefresh = graph.beginSourceSetRefresh()
        XCTAssertEqual(graph.sourceSetAuthority, .hydrating)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)

        let restored = try XCTUnwrap(graph.failSourceSetRefresh(using: failedRefresh))
        XCTAssertEqual(graph.sourceSetAuthority, .authoritative)
        XCTAssertEqual(restored.retentionScope.uids, [retained.uid])
        XCTAssertTrue(restored.retentionScope.isAuthoritative)
    }

    func testAuthoritativeSourceSetReplacementRevokesMissingSources() throws {
        let firstOnly = item("first-only", time: 10)
        let secondOnly = item("second-only", time: 20)
        var graph = LibrarySourceGraph()
        let initialSet = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource, secondSource], using: initialSet))
        _ = install(firstSource, items: [firstOnly], in: &graph)
        _ = install(secondSource, items: [secondOnly], in: &graph)

        let replacement = graph.beginSourceSetRefresh()
        let change = try XCTUnwrap(graph.commitSourceSet([secondSource], using: replacement))

        XCTAssertEqual(change.orphanedUIDs, [firstOnly.uid])
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .accessLost)
        XCTAssertEqual(change.retentionScope.uids, [secondOnly.uid])
        XCTAssertTrue(change.retentionScope.isAuthoritative)
    }

    func testSourceSetReplacementDefersOrphansUntilNewSourcesAreHydrated() throws {
        let existing = item("existing", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [existing], in: &graph)

        let replacement = graph.beginSourceSetRefresh()
        let catalogChange = try XCTUnwrap(
            graph.commitSourceSet([secondSource], using: replacement)
        )

        XCTAssertFalse(catalogChange.retentionScope.isAuthoritative)
        XCTAssertTrue(catalogChange.orphanedUIDs.isEmpty)

        let hydration = try XCTUnwrap(graph.beginRefresh(secondSource.id))
        let hydrated = try XCTUnwrap(
            graph.commit([], validationToken: nil, using: hydration)
        )
        XCTAssertTrue(hydrated.retentionScope.isAuthoritative)
        XCTAssertTrue(hydrated.orphanedUIDs.isEmpty)
        XCTAssertFalse(hydrated.retentionScope.uids.contains(existing.uid))
    }

    func testStaleSourceSetDiscoveryCannotRevokeCurrentSources() throws {
        var graph = LibrarySourceGraph()
        let stale = graph.beginSourceSetRefresh()
        let current = graph.beginSourceSetRefresh()

        XCTAssertNil(graph.commitSourceSet([firstSource], using: stale))
        _ = try XCTUnwrap(graph.commitSourceSet([secondSource], using: current))
        XCTAssertNil(graph.inventory(for: firstSource.id))
        XCTAssertNotNil(graph.inventory(for: secondSource.id))
    }

    func testCatalogLeaseCapturedBeforeAccessLossCannotReactivateSource() throws {
        let resource = item("resource", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [resource], in: &graph)
        let staleCatalog = graph.beginSourceSetRefresh()

        _ = try XCTUnwrap(graph.removeSource(firstSource.id))

        XCTAssertNil(graph.commitSourceSet([firstSource], using: staleCatalog))
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .accessLost)
        XCTAssertTrue(graph.retentionProjection().timeline.snapshot.isEmpty)
    }

    func testAcceptedSourceSetDiscoveryLeaseCannotBeReplayed() throws {
        var graph = LibrarySourceGraph()
        let accepted = graph.beginSourceSetRefresh()

        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: accepted))

        XCTAssertNil(graph.commitSourceSet([secondSource], using: accepted))
        XCTAssertNotNil(graph.inventory(for: firstSource.id))
        XCTAssertNil(graph.inventory(for: secondSource.id))
    }

    func testAcceptedOrFailedRefreshLeaseCannotBeReplayed() throws {
        let original = item("original", time: 10)
        let replacement = item("replacement", time: 20)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [original], in: &graph)
        let accepted = try XCTUnwrap(graph.beginRefresh(firstSource.id))

        _ = try XCTUnwrap(
            graph.commit([.complete(replacement)], validationToken: nil, using: accepted)
        )
        XCTAssertNil(graph.commit([.complete(original)], validationToken: nil, using: accepted))
        XCTAssertEqual(graph.retentionProjection().timeline.uids, [replacement.uid])

        let failed = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(graph.failRefresh(using: failed))
        XCTAssertNil(graph.failRefresh(using: failed))
        XCTAssertNil(graph.commit([.complete(original)], validationToken: nil, using: failed))
        XCTAssertEqual(graph.retentionProjection().timeline.uids, [replacement.uid])
    }

    func testLeasesCannotCrossGraphEpochsWithMatchingNumericGenerations() throws {
        let resource = item("resource", time: 10)
        var oldGraph = LibrarySourceGraph()
        let oldCatalogLease = oldGraph.beginSourceSetRefresh()
        _ = try XCTUnwrap(oldGraph.commitSourceSet([firstSource], using: oldCatalogLease))
        let oldRefreshLease = try XCTUnwrap(oldGraph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(
            oldGraph.commit([.complete(resource)], validationToken: nil, using: oldRefreshLease)
        )
        let oldAccessLease = try XCTUnwrap(
            oldGraph.accessLease(for: resource.uid, requiring: .readContent)
        )

        var replacementGraph = LibrarySourceGraph()
        let replacementCatalogLease = replacementGraph.beginSourceSetRefresh()
        XCTAssertNil(replacementGraph.commitSourceSet([firstSource], using: oldCatalogLease))
        _ = try XCTUnwrap(
            replacementGraph.commitSourceSet([firstSource], using: replacementCatalogLease)
        )
        let replacementRefreshLease = try XCTUnwrap(
            replacementGraph.beginRefresh(firstSource.id)
        )
        XCTAssertNil(
            replacementGraph.commit(
                [.complete(resource)],
                validationToken: nil,
                using: oldRefreshLease
            )
        )
        _ = try XCTUnwrap(
            replacementGraph.commit(
                [.complete(resource)],
                validationToken: nil,
                using: replacementRefreshLease
            )
        )
        XCTAssertFalse(replacementGraph.isCurrent(oldAccessLease))
    }

    func testThumbnailOnlySourceCanEnterAnalysisWithoutEnteringProjection() throws {
        let thumbnailOnly = LibrarySource(
            id: SourceID("thumbnail-only"),
            capabilities: [.readThumbnail],
            precedence: 1
        )
        var graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()

        XCTAssertNotNil(graph.commitSourceSet([thumbnailOnly], using: sourceSetLease))
        let refresh = try XCTUnwrap(graph.beginRefresh(thumbnailOnly.id))
        let partial = LibrarySourceItem(
            item: item("partial", time: 0, mediaType: ""),
            knownFields: []
        )
        let change = try XCTUnwrap(
            graph.commit([partial], validationToken: nil, using: refresh)
        )

        XCTAssertNotNil(graph.inventory(for: thumbnailOnly.id))
        XCTAssertEqual(change.analysisScope.uids, [partial.uid])
        XCTAssertTrue(change.analysisScope.isAuthoritative)
        XCTAssertTrue(change.selectedProjection.timeline.uids.isEmpty)
    }

    func testRestoredThumbnailOnlyInventoryKeepsPartialAnalysisMembership() throws {
        let source = LibrarySource(
            id: SourceID("restored-thumbnail-only"),
            capabilities: .readThumbnail,
            isIncluded: false
        )
        let partial = LibrarySourceItem(
            item: item("restored-partial", time: 0, mediaType: ""),
            knownFields: []
        )
        let graph = try LibrarySourceGraph(
            restoring: [
                LibrarySourceInventory(
                    source: source,
                    accessState: .available,
                    authority: .authoritative,
                    items: [partial]
                )
            ]
        )

        XCTAssertEqual(graph.analysisDerivedDataScope().uids, [partial.uid])
        XCTAssertFalse(graph.analysisDerivedDataScope().isAuthoritative)
        XCTAssertTrue(graph.selectedProjection().timeline.uids.isEmpty)
    }

    func testThumbnailOnlySourceDoesNotBlockVideoRetentionAuthority() throws {
        let owner = item(
            "video-owner",
            time: 10,
            isLivePhoto: true,
            relatedVideoID: "video-motion"
        )
        let thumbnailOnly = LibrarySource(
            id: SourceID("analysis-without-content"),
            capabilities: .readThumbnail,
            isIncluded: false
        )
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [owner], in: &graph)
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(
            graph.commitSourceSet([firstSource, thumbnailOnly], using: sourceSetLease)
        )
        let refresh = try XCTUnwrap(graph.beginRefresh(thumbnailOnly.id))
        let partial = LibrarySourceItem(
            item: item("analysis-only", time: 0, mediaType: ""),
            knownFields: []
        )
        let change = try XCTUnwrap(
            graph.commit([partial], validationToken: nil, using: refresh)
        )

        XCTAssertTrue(change.videoRetentionScope.isAuthoritative)
        XCTAssertEqual(
            change.videoRetentionScope.uids,
            [owner.uid, PhotoUID(volumeID: owner.uid.volumeID, nodeID: "video-motion")]
        )
    }

    func testLossOfContentCapabilityKeepsMembershipAndDisablesContentRoute() throws {
        let resource = item("resource", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [resource], in: &graph)
        let incomplete = LibrarySource(
            id: firstSource.id,
            capabilities: [.readMetadata, .readThumbnail],
            precedence: firstSource.precedence
        )

        let catalogLease = graph.beginSourceSetRefresh()
        let change = try XCTUnwrap(
            graph.commitSourceSet([incomplete], using: catalogLease)
        )

        XCTAssertEqual(graph.inventory(for: firstSource.id)?.accessState, .available)
        XCTAssertTrue(change.orphanedUIDs.isEmpty)
        XCTAssertEqual(change.analysisScope.uids, [resource.uid])
        XCTAssertNil(graph.accessLease(for: resource.uid, requiring: .readContent))
        XCTAssertTrue(change.retentionScope.isAuthoritative)
    }

    func testPartialItemsCanDriveAnalysisButDuplicatesRemainInvalid() {
        let resource = item("invalid-inventory", time: 10)
        var graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([firstSource], using: sourceSetLease)
        let incompleteLease = try! XCTUnwrap(graph.beginRefresh(firstSource.id))
        let incomplete = LibrarySourceItem(
            item: resource,
            knownFields: [.captureTime]
        )

        let partialChange = graph.commit([incomplete], validationToken: nil, using: incompleteLease)
        XCTAssertEqual(partialChange?.analysisScope.uids, [resource.uid])
        XCTAssertTrue(partialChange?.analysisScope.isAuthoritative == true)
        XCTAssertTrue(partialChange?.selectedProjection.timeline.uids.isEmpty == true)

        let duplicateLease = try! XCTUnwrap(graph.beginRefresh(firstSource.id))
        let complete = LibrarySourceItem.complete(resource)
        XCTAssertNil(
            graph.commit([complete, complete], validationToken: nil, using: duplicateLease)
        )
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.items, [incomplete])
    }

    func testRestoredAccessLossRemainsATombstoneWithoutAuthority() throws {
        let removed = LibrarySourceInventory(
            source: firstSource,
            accessState: .accessLost,
            authority: .authoritative,
            items: [],
            validationToken: nil
        )
        let graph = try LibrarySourceGraph(restoring: [removed])

        XCTAssertTrue(graph.retentionProjection().timeline.snapshot.isEmpty)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)
        XCTAssertEqual(graph.inventory(for: firstSource.id)?.items, [])
        XCTAssertNil(graph.inventory(for: firstSource.id)?.validationToken)
    }

    func testContentLeaseSurvivesRefreshButNotAccessLoss() throws {
        let resource = item("resource", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [resource], in: &graph)
        let contentLease = try XCTUnwrap(graph.accessLease(for: resource.uid, requiring: .readContent))

        let refreshLease = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        XCTAssertTrue(graph.isCurrent(contentLease))
        _ = try XCTUnwrap(
            graph.commit([.complete(resource)], validationToken: "next", using: refreshLease)
        )
        XCTAssertTrue(graph.isCurrent(contentLease))

        _ = try XCTUnwrap(graph.removeSource(firstSource.id))
        XCTAssertFalse(graph.isCurrent(contentLease))
    }

    func testContentLeaseCannotBecomeCurrentAgainAfterMembershipReappears() throws {
        let resource = item("resource", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [resource], in: &graph)
        let oldLease = try XCTUnwrap(graph.accessLease(for: resource.uid, requiring: .readContent))

        let removal = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(graph.commit([], validationToken: nil, using: removal))
        XCTAssertFalse(graph.isCurrent(oldLease))

        let readdition = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(
            graph.commit([.complete(resource)], validationToken: nil, using: readdition)
        )
        XCTAssertFalse(graph.isCurrent(oldLease))
        XCTAssertNotNil(graph.accessLease(for: resource.uid, requiring: .readContent))
    }

    func testCapabilityLeaseCannotBecomeCurrentAgainAfterCapabilityReappears() throws {
        let resource = item("resource", time: 10)
        let writable = LibrarySource(
            id: firstSource.id,
            capabilities: firstSource.capabilities.union(.writeContent),
            precedence: firstSource.precedence
        )
        var graph = LibrarySourceGraph()
        _ = install(writable, items: [resource], in: &graph)
        let oldLease = try XCTUnwrap(graph.accessLease(for: resource.uid, requiring: .writeContent))

        let removal = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: removal))
        XCTAssertFalse(graph.isCurrent(oldLease))

        let readdition = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([writable], using: readdition))
        XCTAssertFalse(graph.isCurrent(oldLease))
        XCTAssertNotNil(graph.accessLease(for: resource.uid, requiring: .writeContent))
    }

    func testAccessRouteFallsBackAndCanExcludeSourcesOutsideMainProjection() throws {
        let resource = item("resource", time: 10)
        let excluded = LibrarySource(
            id: firstSource.id,
            capabilities: firstSource.capabilities,
            precedence: firstSource.precedence,
            isIncluded: false
        )
        var graph = LibrarySourceGraph()
        _ = install(excluded, items: [resource], in: &graph)
        _ = install(secondSource, items: [resource], in: &graph)

        XCTAssertEqual(
            graph.accessLease(for: resource.uid, requiring: .readThumbnail)?.sourceID,
            excluded.id
        )
        XCTAssertEqual(
            graph.accessLease(
                for: resource.uid,
                requiring: .readThumbnail,
                includeExcludedSources: false
            )?.sourceID,
            secondSource.id
        )
    }

    func testSelectedAccessLeaseCannotBecomeCurrentAfterExclusionToggle() throws {
        let resource = item("resource", time: 10)
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [resource], in: &graph)
        let selectedLease = try XCTUnwrap(
            graph.accessLease(
                for: resource.uid,
                requiring: .readContent,
                includeExcludedSources: false
            )
        )

        _ = try XCTUnwrap(graph.setIncluded(false, for: firstSource.id))
        XCTAssertFalse(graph.isCurrent(selectedLease))

        _ = try XCTUnwrap(graph.setIncluded(true, for: firstSource.id))
        XCTAssertFalse(graph.isCurrent(selectedLease))
    }

    func testRelationshipRetentionAndRoutingUseUnionOfExactSourceMemberships() throws {
        let preferred = item(
            "owner",
            time: 10,
            isLivePhoto: true,
            relatedVideoID: "motion-first",
            burstMemberIDs: ["burst-first"]
        )
        let fallback = item(
            "owner",
            time: 10,
            isLivePhoto: true,
            relatedVideoID: "motion-second",
            burstMemberIDs: ["burst-second"]
        )
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [preferred], in: &graph)
        let change = install(secondSource, items: [fallback], in: &graph)
        let motionFirst = PhotoUID(volumeID: preferred.uid.volumeID, nodeID: "motion-first")
        let motionSecond = PhotoUID(volumeID: preferred.uid.volumeID, nodeID: "motion-second")
        let burstFirst = PhotoUID(volumeID: preferred.uid.volumeID, nodeID: "burst-first")
        let burstSecond = PhotoUID(volumeID: preferred.uid.volumeID, nodeID: "burst-second")

        XCTAssertEqual(change.retentionScope.uids, [preferred.uid])
        XCTAssertEqual(
            change.videoRetentionScope.uids,
            [preferred.uid, motionFirst, motionSecond]
        )
        XCTAssertEqual(
            change.thumbnailRetentionScope.uids,
            [preferred.uid, burstFirst, burstSecond]
        )
        XCTAssertTrue(change.videoRetentionScope.isAuthoritative)
        XCTAssertTrue(change.thumbnailRetentionScope.isAuthoritative)
        XCTAssertEqual(
            change.selectedProjection.sourceID(
                for: preferred.uid,
                metadataField: .livePhotoRelationship
            ),
            firstSource.id
        )
        XCTAssertNil(graph.accessLease(for: motionFirst, requiring: .readContent))

        let firstMotionLease = try XCTUnwrap(
            graph.relatedAccessLease(
                for: motionFirst,
                of: preferred.uid,
                relationship: .livePhotoMotion,
                requiring: .readContent
            )
        )
        let secondMotionLease = try XCTUnwrap(
            graph.relatedAccessLease(
                for: motionSecond,
                of: preferred.uid,
                relationship: .livePhotoMotion,
                requiring: .readContent
            )
        )
        XCTAssertEqual(firstMotionLease.sourceID, firstSource.id)
        XCTAssertEqual(secondMotionLease.sourceID, secondSource.id)

        let replacement = item(
            "owner",
            time: 10,
            isLivePhoto: true,
            relatedVideoID: "motion-replacement",
            burstMemberIDs: ["burst-replacement"]
        )
        let refresh = try XCTUnwrap(graph.beginRefresh(secondSource.id))
        let replaced = try XCTUnwrap(
            graph.commit([.complete(replacement)], validationToken: nil, using: refresh)
        )

        XCTAssertTrue(graph.isCurrent(firstMotionLease))
        XCTAssertFalse(graph.isCurrent(secondMotionLease))
        XCTAssertFalse(replaced.videoRetentionScope.uids.contains(motionSecond))
        XCTAssertFalse(replaced.thumbnailRetentionScope.uids.contains(burstSecond))
    }

    func testUnknownRelationshipCannotAuthorizeRelatedResourceDeletion() throws {
        let owner = item("owner", time: 10)
        var graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: sourceSetLease))
        let refresh = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        let change = try XCTUnwrap(
            graph.commit(
                [
                    LibrarySourceItem(
                        item: owner,
                        knownFields: [.captureTime, .mediaType, .burstRelationship]
                    )
                ],
                validationToken: nil,
                using: refresh
            )
        )

        XCTAssertTrue(change.retentionScope.isAuthoritative)
        XCTAssertTrue(change.thumbnailRetentionScope.isAuthoritative)
        XCTAssertTrue(change.videoRetentionScope.isAuthoritative)
        XCTAssertEqual(change.videoRetentionScope.uids, [owner.uid])
    }

    func testTenThousandRelationshipRoutesDoNotRescanInventories() {
        let count = 10_000
        let items = (0..<count).map { index in
            item(
                "owner-\(index)",
                time: TimeInterval(index),
                isLivePhoto: true,
                relatedVideoID: "motion-\(index)"
            )
        }
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: items, in: &graph)

        let started = ContinuousClock.now
        var resolved = 0
        for index in 0..<count {
            let ownerUID = PhotoUID(volumeID: "volume", nodeID: "owner-\(index)")
            let motionUID = PhotoUID(volumeID: "volume", nodeID: "motion-\(index)")
            if graph.relatedAccessLease(
                for: motionUID,
                of: ownerUID,
                relationship: .livePhotoMotion,
                requiring: .readContent
            )?.sourceID == firstSource.id {
                resolved += 1
            }
        }
        let elapsed = started.duration(to: ContinuousClock.now)

        XCTAssertEqual(resolved, count)
        // A UID index keeps this O(items). A per-lease inventory scan would be O(items squared).
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testCombinedSnapshotMatchesIndependentScopesAcrossInclusionAndCapabilityChanges() throws {
        var graph = LibrarySourceGraph()
        let primary = item("same", time: 10, isLivePhoto: true, relatedVideoID: "motion", burstMemberIDs: ["burst"])
        let thumbnailOnly = LibrarySource(id: SourceID("thumbnail-only"), capabilities: [.readThumbnail])
        func checkSnapshot() {
            let change = graph.snapshot()
            XCTAssertEqual(change.selectedProjection.timeline.snapshot, graph.selectedProjection().timeline.snapshot)
            XCTAssertEqual(change.retentionProjection.timeline.snapshot, graph.retentionProjection().timeline.snapshot)
            XCTAssertEqual(change.selectedScope, graph.selectedDerivedDataScope())
            XCTAssertEqual(change.analysisScope, graph.analysisDerivedDataScope())
            XCTAssertEqual(change.retentionScope, graph.retentionDerivedDataScope())
            XCTAssertEqual(change.thumbnailRetentionScope, graph.thumbnailRetentionDerivedDataScope())
            XCTAssertEqual(change.videoRetentionScope, graph.videoRetentionDerivedDataScope())
        }
        checkSnapshot()
        _ = install(firstSource, items: [primary, item("earlier", time: 1)], in: &graph)
        checkSnapshot()
        _ = install(thumbnailOnly, items: [item("same", time: 20), item("additional", time: 30)], in: &graph)
        checkSnapshot()
        _ = graph.setIncluded(false, for: thumbnailOnly.id)
        checkSnapshot()
        _ = graph.setIncluded(false, for: firstSource.id)
        checkSnapshot()
        _ = graph.removeSource(firstSource.id)
        checkSnapshot()
        _ = graph.removeSource(thumbnailOnly.id)
        checkSnapshot()
    }

    func testPersistenceSignatureIgnoresNoOpRefreshChurnButTracksPayloadAndOverlayChanges() throws {
        var graph = LibrarySourceGraph()
        _ = install(firstSource, items: [item("asset", time: 1)], in: &graph)
        let initial = graph.persistenceSignature(additionalStateGeneration: 0)

        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = try XCTUnwrap(graph.commitSourceSet([firstSource], using: sourceSetLease))
        let unchangedRefresh = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(
            graph.commit(
                [.complete(item("asset", time: 1))],
                validationToken: nil,
                using: unchangedRefresh
            )
        )
        XCTAssertEqual(graph.persistenceSignature(additionalStateGeneration: 0), initial)

        let changedRefresh = try XCTUnwrap(graph.beginRefresh(firstSource.id))
        _ = try XCTUnwrap(
            graph.commit(
                [.complete(item("asset", time: 2))],
                validationToken: nil,
                using: changedRefresh
            )
        )
        let changed = graph.persistenceSignature(additionalStateGeneration: 0)
        XCTAssertNotEqual(changed, initial)
        XCTAssertNotEqual(
            graph.persistenceSignature(additionalStateGeneration: 1),
            changed
        )
    }
}
