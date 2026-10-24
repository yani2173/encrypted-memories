import Foundation
import Testing

@testable import MediaCacheCore

/// Explicit limit changes and purges are deterministic; `NSCache`'s lazy eviction heuristics are not asserted.
@Suite struct WrapperImageCacheTests {
    private final class Wrapped {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    @Test func invalidationBeforeSourceLookupRejectsTheOldTicketWithoutBuilding() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        let ticket = cache.captureTicket()
        let source = Wrapped(1)
        var buildCount = 0

        cache.invalidateAll()
        let result = cache.resolvePairedImage(
            forKey: "photo",
            cost: 10,
            source: source,
            ticket: ticket,
            sourceIsCurrent: { true },
            build: {
                buildCount += 1
                return Wrapped(10)
            }
        )

        #expect(result == nil)
        #expect(buildCount == 0)
    }

    @Test func invalidationDuringConstructionReturnsNoRevokedWrapperOrReinsertion() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        let ticket = cache.captureTicket()
        weak var releasedWrapper: Wrapped?
        weak var releasedSource: Wrapped?
        do {
            let source = Wrapped(1)
            releasedSource = source
            let result = cache.resolvePairedImage(
                forKey: "photo",
                cost: 10,
                source: source,
                ticket: ticket,
                sourceIsCurrent: { true },
                build: {
                    let wrapper = Wrapped(10)
                    releasedWrapper = wrapper
                    cache.invalidateAll()
                    return wrapper
                }
            )
            #expect(result == nil)
        }
        #expect(releasedWrapper == nil)
        #expect(releasedSource == nil)
        #expect(cache.image(forKey: "photo") == nil)
    }

    @Test func perKeyInvalidationReleasesThePairedSourceWithoutLeavingAMarker() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        weak var releasedSource: Wrapped?
        do {
            let source = Wrapped(1)
            releasedSource = source
            let ticket = cache.captureTicket()
            #expect(cache.setPaired(Wrapped(10), forKey: "photo", cost: 10, source: source, ticket: ticket))
        }
        #expect(releasedSource != nil)

        cache.invalidatePaired(forKey: "photo")

        #expect(releasedSource == nil)
        #expect(cache.image(forKey: "photo") == nil)
    }

    @Test func unrelatedKeyInvalidationDoesNotRejectAnInFlightBuilder() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        let sourceA = Wrapped(1)
        let ticketA = cache.captureTicket()

        let imageA = cache.resolvePairedImage(
            forKey: "a",
            cost: 10,
            source: sourceA,
            ticket: ticketA,
            sourceIsCurrent: { true },
            build: {
                cache.invalidatePaired(forKey: "b")
                return Wrapped(10)
            }
        )

        #expect(imageA?.id == 10)
        #expect(cache.pairedImage(forKey: "a", source: sourceA, ticket: ticketA)?.id == 10)
    }

    @Test func sourceReplacementDuringConstructionReturnsNilAndTheCurrentSourceCanBuild() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        let oldSource = Wrapped(1)
        let newSource = Wrapped(2)
        var currentSource = oldSource
        let oldTicket = cache.captureTicket()

        let oldImage = cache.resolvePairedImage(
            forKey: "photo",
            cost: 10,
            source: oldSource,
            ticket: oldTicket,
            sourceIsCurrent: { currentSource === oldSource },
            build: {
                currentSource = newSource
                return Wrapped(10)
            }
        )
        #expect(oldImage == nil)

        let newTicket = cache.captureTicket()
        let newImage = cache.resolvePairedImage(
            forKey: "photo",
            cost: 10,
            source: newSource,
            ticket: newTicket,
            sourceIsCurrent: { currentSource === newSource },
            build: { Wrapped(20) }
        )
        #expect(newImage?.id == 20)
        #expect(cache.pairedImage(forKey: "photo", source: newSource, ticket: newTicket)?.id == 20)
    }

    @Test func purgeInvalidatesPendingTicketsWithoutAParallelSourceTable() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        let ticket = cache.captureTicket()

        cache.purge(keeping: nil)

        #expect(!cache.isCurrent(ticket))
        #expect(!cache.setPaired(Wrapped(11), forKey: "late", cost: 10, source: Wrapped(2), ticket: ticket))
    }

    @Test func pressureScaleLowersAndRestoresTheCostLimit() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        #expect(cache.currentCostLimitBytes == 1_000)

        cache.applyMemoryPressure(scale: 0.5, purge: false)
        #expect(cache.currentCostLimitBytes == 500)

        cache.applyMemoryPressure(scale: 0.0, purge: false)
        #expect(cache.currentCostLimitBytes == 1)  // never zero; NSCache treats 0 as "no limit"

        cache.applyMemoryPressure(scale: 1.0, purge: false)
        #expect(cache.currentCostLimitBytes == 1_000)

        cache.applyMemoryPressure(scale: 7.0, purge: false)  // clamped
        #expect(cache.currentCostLimitBytes == 1_000)
    }

    @Test func purgeDropsHeldEntriesButScaleAloneDoesNot() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000_000)
        cache.set(Wrapped(1), forKey: "a", cost: 10)
        cache.set(Wrapped(2), forKey: "b", cost: 10)
        #expect(cache.image(forKey: "a") != nil)

        cache.applyMemoryPressure(scale: 0.5, purge: false)  // "reduce future budgets" semantic
        #expect(cache.image(forKey: "a") != nil)
        #expect(cache.image(forKey: "b") != nil)

        cache.applyMemoryPressure(scale: 0.0, purge: true)  // critical semantic: drop now
        #expect(cache.image(forKey: "a") == nil)
        #expect(cache.image(forKey: "b") == nil)
    }

    @Test func purgeKeepingRetainsOnlyTheKeptEntry() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000_000)
        cache.set(Wrapped(1), forKey: "visible", cost: 10)
        cache.set(Wrapped(2), forKey: "offscreen-1", cost: 10)
        cache.set(Wrapped(3), forKey: "offscreen-2", cost: 10)

        cache.purge(keeping: "visible", keptCost: 10)
        #expect(cache.image(forKey: "visible")?.id == 1)
        #expect(cache.image(forKey: "offscreen-1") == nil)
        #expect(cache.image(forKey: "offscreen-2") == nil)

        cache.purge(keeping: nil)
        #expect(cache.image(forKey: "visible") == nil)
    }
}
