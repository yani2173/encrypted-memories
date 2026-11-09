import Foundation
import Testing

@testable import PhotosCore

/// When a background window ends before its account is ready, and when it keeps waiting.
@Suite @MainActor struct BackgroundAccountReadinessTests {
    private final class Service: Sendable {}

    private final class Rereads {
        var count = 0
    }

    private final class GraceRuns: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0
        var count: Int { lock.withLock { runs } }
        func run() { lock.withLock { runs += 1 } }
    }

    private static func reason(_ wait: BackgroundAccountWait<Service>) -> BackgroundWindowOutcome? {
        guard case .cannotRun(let reason) = wait else { return nil }
        return reason
    }

    private static func service(_ wait: BackgroundAccountWait<Service>) -> Service? {
        guard case .ready(let service) = wait else { return nil }
        return service
    }

    /// A grace that reports its start and ends when the test releases it or its task is cancelled.
    private static func heldGrace() -> (
        grace: @Sendable () async -> Void, started: AsyncStream<Void>, release: @Sendable () -> Void
    ) {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (released, releasedContinuation) = AsyncStream<Void>.makeStream()
        return (
            {
                startedContinuation.yield()
                for await _ in released { break }
            }, started, { releasedContinuation.yield() }
        )
    }

    /// Waits at most five seconds for the held grace to start, so a window that never reaches it fails the test
    /// instead of hanging it.
    private static func didStart(_ started: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = started.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func aReadThatFoundNoSignInEndsTheWindowAtOnceWithNoAccount() async {
        let readiness = BackgroundAccountReadiness(grace: {})
        let reference = WeakAsyncReference<Service>()
        readiness.record(.absent)
        let wait = await readiness.wait(for: reference, timeout: .seconds(2))
        #expect(Self.reason(wait) == .noAccount)
    }

    @Test func aRefusedReadThatTheWindowsOwnReReadConfirmsEndsTheWindowAtOnceAsLocked() async {
        let graceRuns = GraceRuns()
        let readiness = BackgroundAccountReadiness(grace: { graceRuns.run() })
        let reference = WeakAsyncReference<Service>()
        let rereads = Rereads()
        readiness.installReread {
            rereads.count += 1
            readiness.record(.unreadable)
        }
        readiness.record(.unreadable)
        let wait = await readiness.wait(for: reference, timeout: .seconds(2))
        #expect(Self.reason(wait) == .endedAtOnceLocked)
        #expect(rereads.count == 1, "the window reads the sign-in once more itself")
        #expect(graceRuns.count == 1, "the window first gives the app the grace to read after an unlock")
    }

    /// The window asks for one read, but the app makes none, for example while its startup cleanup runs. The old
    /// refused read alone never ends the window.
    @Test func aReReadThatTheAppDoesNotMakeKeepsTheBoundedWait() async {
        let readiness = BackgroundAccountReadiness(grace: {})
        let reference = WeakAsyncReference<Service>()
        let rereads = Rereads()
        readiness.installReread { rereads.count += 1 }
        readiness.record(.unreadable)
        let wait = await readiness.wait(for: reference, timeout: .milliseconds(300))
        #expect(Self.reason(wait) == nil, "no read during this window was refused")
        #expect(Self.service(wait) == nil)
        #expect(rereads.count == 1, "the window asks for one read only")
    }

    /// The process read the sign-in before the first unlock since the restart. The phone was unlocked once since then,
    /// so the night window must not end on that old result.
    @Test func aProcessThatReadBeforeTheFirstUnlockRunsItsWindowAfterTheUnlock() async {
        let readiness = BackgroundAccountReadiness(grace: {})
        let reference = WeakAsyncReference<Service>()
        let service = Service()
        let rereads = Rereads()
        readiness.record(.unreadable)
        readiness.installReread {
            rereads.count += 1
            readiness.record(.readable)
            reference.value = service
        }
        let wait = await readiness.wait(for: reference, timeout: .seconds(2))
        #expect(Self.service(wait) === service)
        #expect(Self.reason(wait) == nil)
        #expect(rereads.count == 1)
    }

    @Test func aReadAfterAnUnlockDuringTheGraceWinsWithoutAReRead() async throws {
        let held = Self.heldGrace()
        let readiness = BackgroundAccountReadiness(grace: held.grace)
        let reference = WeakAsyncReference<Service>()
        let service = Service()
        let rereads = Rereads()
        readiness.installReread { rereads.count += 1 }
        readiness.record(.unreadable)
        let window = Task { await readiness.wait(for: reference, timeout: .seconds(30)) }
        try #require(await Self.didStart(held.started), "the window waits for another read after the refused one")
        readiness.record(.readable)
        reference.value = service
        let wait = await window.value
        #expect(Self.service(wait) === service)
        #expect(rereads.count == 0, "the read after the unlock already came during the window")
    }

    /// A refused read during the grace does not shorten it: the window still waits for the end of the grace and then
    /// reads once itself.
    @Test func aRefusedReadDuringTheGraceKeepsTheGraceAndTheOwnReRead() async throws {
        let held = Self.heldGrace()
        let readiness = BackgroundAccountReadiness(grace: held.grace)
        let reference = WeakAsyncReference<Service>()
        let rereads = Rereads()
        readiness.installReread {
            rereads.count += 1
            readiness.record(.unreadable)
        }
        readiness.record(.unreadable)
        let window = Task { await readiness.wait(for: reference, timeout: .seconds(30)) }
        try #require(await Self.didStart(held.started), "the window waits for another read after the refused one")
        readiness.record(.unreadable)
        await Task.yield()
        #expect(rereads.count == 0, "the grace is not over")
        held.release()
        let wait = await window.value
        #expect(Self.reason(wait) == .endedAtOnceLocked)
        #expect(rereads.count == 1, "after the grace the window read once itself")
    }

    /// A cold launch: the first read during the window is refused, and the phone is unlocked two seconds later. The
    /// unlock makes the app read again, and the window runs.
    @Test func aFreshRefusedReadGetsTheGraceSoAnUnlockLetsTheWindowRun() async {
        let held = Self.heldGrace()
        let readiness = BackgroundAccountReadiness(grace: held.grace)
        let reference = WeakAsyncReference<Service>()
        let service = Service()
        let rereads = Rereads()
        readiness.installReread { rereads.count += 1 }
        let window = Task { await readiness.wait(for: reference, timeout: .seconds(30)) }
        await Task.yield()
        readiness.record(.unreadable)
        let graceStarted = await Self.didStart(held.started)
        readiness.record(.readable)
        reference.value = service
        let wait = await window.value
        #expect(graceStarted, "the fresh refused read gets the grace")
        #expect(Self.service(wait) === service, "the read after the unlock lets the window run")
        #expect(Self.reason(wait) == nil)
        #expect(rereads.count == 0)
    }

    @Test func aWindowBeforeAnyReadKeepsWaitingForTheService() async {
        let readiness = BackgroundAccountReadiness(grace: {})
        let reference = WeakAsyncReference<Service>()
        let service = Service()
        let window = Task { await readiness.wait(for: reference, timeout: .seconds(30)) }
        await Task.yield()
        readiness.record(.readable)
        reference.value = service
        let wait = await window.value
        #expect(Self.service(wait) === service)
    }

    @Test func aWindowWithoutADecidingReadEndsOnlyAtTheLimit() async {
        let readiness = BackgroundAccountReadiness(grace: {})
        let reference = WeakAsyncReference<Service>()
        let rereads = Rereads()
        readiness.installReread { rereads.count += 1 }
        readiness.record(.notYet)
        let clock = ContinuousClock()
        let start = clock.now
        let wait = await readiness.wait(for: reference, timeout: .milliseconds(300))
        #expect(Self.reason(wait) == nil)
        #expect(Self.service(wait) == nil)
        #expect(clock.now - start >= .milliseconds(300), "a read that decides nothing keeps the bounded wait")
        #expect(rereads.count == 0)
    }

    @Test func aCancelledWindowEndsItsWaitWithoutAReRead() async throws {
        let held = Self.heldGrace()
        let readiness = BackgroundAccountReadiness(grace: held.grace)
        let reference = WeakAsyncReference<Service>()
        let rereads = Rereads()
        readiness.installReread { rereads.count += 1 }
        readiness.record(.unreadable)
        let window = Task { await readiness.wait(for: reference, timeout: .seconds(1)) }
        try #require(await Self.didStart(held.started), "the window waits for another read after the refused one")
        window.cancel()
        held.release()
        let wait = await window.value
        #expect(Self.reason(wait) == nil)
        #expect(Self.service(wait) == nil)
        #expect(rereads.count == 0, "a cancelled window never reads, also when its grace ends")
    }

    @Test func aWindowWithoutItsServiceRecordsWhyAndAnExpiryDecidesFirst() {
        let locked = BackgroundAccountWait<Service>.cannotRun(.endedAtOnceLocked)
        let noAccount = BackgroundAccountWait<Service>.cannotRun(.noAccount)
        let late = BackgroundAccountWait<Service>.notReady
        #expect(locked.outcomeWithoutService(didExpire: false) == .endedAtOnceLocked)
        #expect(noAccount.outcomeWithoutService(didExpire: false) == .noAccount)
        #expect(late.outcomeWithoutService(didExpire: false) == .failed)
        #expect(locked.outcomeWithoutService(didExpire: true) == .expired)
        #expect(noAccount.outcomeWithoutService(didExpire: true) == .expired)
        #expect(late.outcomeWithoutService(didExpire: true) == .expired)
        #expect(!BackgroundWindowOutcome.endedAtOnceLocked.reportsSuccess, "the OS hears failure, as before")
        #expect(!BackgroundWindowOutcome.noAccount.reportsSuccess)
    }

    @Test func aPassThatWaitedForTheNetworkUntilTheWindowEndedRecordsNoNetwork() {
        let after = BackgroundWindowOutcome.afterWork(didExpire:didComplete:waitedForNetwork:)
        #expect(after(true, false, true) == .noNetwork, "the window expired while its pass waited for the path")
        #expect(after(false, true, true) == .noNetwork)
        #expect(after(true, false, false) == .expired)
        #expect(after(false, true, false) == .ran)
        #expect(BackgroundWindowOutcome.noNetwork.afterTheEndWait(didExpire: true) == .noNetwork)
        #expect(!BackgroundWindowOutcome.noNetwork.reportsSuccess, "the OS hears failure, as for the expiry before")
    }
}
