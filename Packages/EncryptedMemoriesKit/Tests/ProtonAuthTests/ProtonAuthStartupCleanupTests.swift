import Foundation
import PhotosCore
import Testing

@testable import ProtonAuth

@Suite @MainActor struct ProtonAuthStartupCleanupTests {
    @Test func signInWaitsForAFirstSuccessfulCleanup() {
        let fixture = Fixture()
        #expect(!fixture.cleanup.succeeded)
        #expect(fixture.cleanup.admitSignIn() == .cleanUpFirst, "no session starts before the first cleanup")
    }

    @Test func aRunningCleanupHoldsSignInAndCannotStartTwice() async {
        let fixture = Fixture()
        let finished = Finished()

        #expect(fixture.cleanup.begin(plaintextPurgeSucceeded: true) { finished.results.append($0) })
        #expect(fixture.claims.value == 1, "the sign-out purge is claimed before the cleanup runs")
        #expect(fixture.cleanup.isRunning)
        #expect(fixture.cleanup.admitSignIn() == .waitForCleanup)
        #expect(!fixture.cleanup.begin { finished.results.append($0) }, "a second cleanup does not start")
        #expect(fixture.claims.value == 1)

        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [true])
        #expect(await fixture.gate.plaintextPurgeArguments == [true], "the plaintext purge result reaches the cleanup")
    }

    @Test func theClaimedSignOutPurgeReachesTheCleanup() async throws {
        let suite = "startup-cleanup-claim-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        let received = ClaimBox()
        let cleanup = ProtonAuthStartupCleanup(
            claimPurge: { BackupLocalDataPurge.claimSignOutPurge(defaults: defaults, roots: [root]) },
            isPurgePending: { BackupLocalDataPurge.isPurgePending(defaults: defaults) },
            run: { claim, _ in
                await received.set(claim != nil)
                return true
            })
        let finished = Finished()

        cleanup.begin { finished.results.append($0) }
        await finished.wait()

        #expect(await received.hadClaim == true, "the armed purge is handed to the cleanup that deletes the data")
    }

    @Test func theResultIsRecordedBeforeTheHostHearsIt() async {
        let fixture = Fixture()
        let finished = Finished()
        let cleanup = fixture.cleanup
        cleanup.begin { succeeded in
            finished.stateAtFinish = (cleanup.succeeded, cleanup.isRunning)
            finished.results.append(succeeded)
        }

        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.stateAtFinish?.0 == true)
        #expect(finished.stateAtFinish?.1 == false, "a sign-in that the host starts now is admitted")
        #expect(cleanup.admitSignIn() == .proceed)
    }

    @Test func aPendingSignOutPurgeSendsSignInThroughAnotherCleanup() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.release(succeeded: true)
        await finished.wait()

        fixture.pending.value = 1
        #expect(fixture.cleanup.admitSignIn() == .cleanUpFirst)
    }

    @Test func aFailedCleanupKeepsSignInClosedUntilALaterOneSucceeds() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.release(succeeded: false)
        await finished.wait()
        #expect(!fixture.cleanup.succeeded)
        #expect(fixture.cleanup.admitSignIn() == .cleanUpFirst)

        fixture.cleanup.begin { finished.results.append($0) }
        #expect(fixture.claims.value == 2, "every cleanup claims a pending purge again")
        await fixture.gate.release(succeeded: true)
        await finished.wait(count: 2)
        #expect(finished.results == [false, true])
        #expect(fixture.cleanup.admitSignIn() == .proceed)
    }

    @Test func anUnlockDuringAFailingCleanupRunsItAgainBeforeTheFailureCounts() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        // The device unlocks while the first run is inside the cleanup; that run then fails on a protected file.
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.requestRetryIfRunning()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.waitUntilEntered(2)
        #expect(finished.results.isEmpty, "the failure does not reach the host while the second run is open")
        #expect(fixture.cleanup.isRunning)
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [true], "the host hears only the result of the run after the unlock")
        #expect(fixture.claims.value == 2, "the second run claims a pending purge again")
        #expect(fixture.cleanup.admitSignIn() == .proceed)
    }

    @Test func aRunThatStartedLockedRunsAgainWhenTheUnlockCameWithoutItsNotification() async {
        let fixture = Fixture(protectedDataAvailable: false)
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        // The device unlocks, but the unlock notification has not reached the app when the run fails.
        fixture.protectedData.value = 1
        await fixture.gate.release(succeeded: false)
        await fixture.gate.waitUntilEntered(2)
        #expect(finished.results.isEmpty, "the failure from the locked device does not reach the host")
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [true])
    }

    @Test func aRunThatStartedLockedRepeatsOnlyOnceWithoutARequest() async {
        let fixture = Fixture(protectedDataAvailable: false)
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.protectedData.value = 1
        await fixture.gate.release(succeeded: false)
        await fixture.gate.waitUntilEntered(2)
        await fixture.gate.release(succeeded: false)
        await finished.wait()
        #expect(finished.results == [false], "a run that started unlocked and fails counts")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
        await finished.wait()
    }

    @Test func aRetryIsConsumedEvenWhenTheSecondRunFails() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.requestRetryIfRunning()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.waitUntilEntered(2)
        await fixture.gate.release(succeeded: false)
        await finished.wait()
        #expect(finished.results == [false], "one request permits exactly one retry")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
        await finished.wait()
    }

    @Test func aRetryDuringASuccessDoesNotReachTheNextBegin() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.requestRetryIfRunning()
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(2)
        await fixture.gate.release(succeeded: false)
        await finished.wait(count: 2)
        #expect(finished.results == [true, false], "the new chain runs exactly once")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
        await finished.wait(count: 2)
    }

    @Test func aLockDuringAnUnlockedRunIsRememberedUntilItsResult() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.protectedData.value = 0
        fixture.cleanup.noteProtectedDataUnavailable()
        fixture.protectedData.value = 1
        await fixture.gate.release(succeeded: false)
        await fixture.gate.waitUntilEntered(2)
        #expect(finished.results.isEmpty, "the locked run cannot publish a sign-in failure")
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [true])
        await fixture.gate.finishAll()
    }

    @Test func aLockBeforeTheFirstTaskJobIsRememberedUntilItsResult() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        // The will-lock notification arrives before the task starts and before availability changes.
        fixture.cleanup.noteProtectedDataUnavailable()
        await fixture.gate.waitUntilEntered(1)
        fixture.protectedData.value = 0
        fixture.protectedData.value = 1
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [true], "the early lock cannot publish a sign-in failure")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
    }

    @Test func aLockDuringASuccessDoesNotReachTheNextBegin() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.noteProtectedDataUnavailable()
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: true)
        fixture.cleanup.begin { finished.results.append($0) }
        await finished.wait(count: 2)
        #expect(finished.results == [true, false], "the next chain has no lock event")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
    }

    @Test func aRetryAndALockInOneRunDoNotGrantAThirdRun() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.requestRetryIfRunning()
        fixture.cleanup.noteProtectedDataUnavailable()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [false], "the consumed request and lock grant only one retry")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
    }

    @Test func aLockNotificationWithoutARunningCleanupDoesNotGrantARepeat() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.noteProtectedDataUnavailable()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: true)
        fixture.cleanup.begin { finished.results.append($0) }
        await finished.wait()
        #expect(finished.results == [false], "an idle lock event does not reach the next chain")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 1)
        await fixture.gate.finishAll()
    }

    @Test func aLockDuringARunGrantsOnlyOneAutomaticRepeat() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.waitUntilEntered(1)
        fixture.cleanup.noteProtectedDataUnavailable()
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: false)
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(finished.results == [false], "the automatic repeat is used only once")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 2)
        await fixture.gate.finishAll()
    }

    @Test func aLockedDeviceRunsTheCleanupAndKeepsChecking() async {
        let fixture = Fixture(protectedDataAvailable: false)
        let finished = Finished()
        #expect(fixture.cleanup.begin { finished.results.append($0) }, "the cleanup does not wait for an unlock")
        await fixture.gate.waitUntilEntered(1)
        await fixture.gate.release(succeeded: false)
        await finished.wait()
        var bootstraps = 0
        let state = fixture.cleanup.startupState(signInFailed: "failed") {
            bootstraps += 1
            return .signedOut(error: nil)
        }
        #expect(state == .checking, "a failed cleanup on a locked device never looks like a sign-out")
        #expect(bootstraps == 0)

        fixture.protectedData.value = 1
        #expect(
            fixture.cleanup.startupState(signInFailed: "failed") { .signedOut(error: nil) }
                == .signedOut(error: "failed"))
    }

    @Test func aLockedDeviceReadsTheSessionAfterASuccessfulCleanup() async {
        let fixture = Fixture(protectedDataAvailable: false)
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        var bootstraps = 0
        let state = fixture.cleanup.startupState(signInFailed: "failed") {
            bootstraps += 1
            return .checking
        }
        #expect(bootstraps == 1, "the bootstrap does not wait for an unlock")
        #expect(state == .checking)
    }

    @Test func aRetryRequestWithoutARunningCleanupDoesNothing() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.requestRetryIfRunning()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.release(succeeded: false)
        await finished.wait()
        #expect(finished.results == [false], "a request before the cleanup started repeats nothing")
        #expect(await fixture.gate.plaintextPurgeArguments.count == 1)
    }

    @Test func aNewCleanupWithdrawsAnEarlierSuccessWhileItRuns() async {
        let fixture = Fixture()
        let finished = Finished()
        fixture.cleanup.begin { finished.results.append($0) }
        await fixture.gate.release(succeeded: true)
        await finished.wait()
        #expect(fixture.cleanup.succeeded)

        fixture.cleanup.begin { finished.results.append($0) }
        #expect(!fixture.cleanup.succeeded, "a saved session waits for this cleanup as well")
        await fixture.gate.release(succeeded: true)
        await finished.wait(count: 2)
    }
}

@MainActor
private struct Fixture {
    let claims = Counter()
    let pending = Counter()
    /// 1 while protected data can be read.
    let protectedData = Counter()
    let gate = CleanupGate()
    let cleanup: ProtonAuthStartupCleanup

    init(protectedDataAvailable: Bool = true) {
        let claims = claims
        let pending = pending
        let gate = gate
        let protectedData = protectedData
        protectedData.value = protectedDataAvailable ? 1 : 0
        cleanup = ProtonAuthStartupCleanup(
            claimPurge: {
                claims.value += 1
                return nil
            },
            isPurgePending: { pending.value > 0 },
            run: { _, plaintextPurgeSucceeded in await gate.run(plaintextPurgeSucceeded) },
            isProtectedDataAvailable: { protectedData.value == 1 })
    }
}

/// Holds each cleanup run until the test releases it with a result.
private actor CleanupGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var results: [Bool] = []
    private var finished = false
    private(set) var plaintextPurgeArguments: [Bool?] = []

    /// Waits up to 10 s until `count` runs have entered the cleanup.
    func waitUntilEntered(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while plaintextPurgeArguments.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(plaintextPurgeArguments.count >= count, "run \(count) entered the cleanup")
    }

    func run(_ plaintextPurgeSucceeded: Bool?) async -> Bool {
        plaintextPurgeArguments.append(plaintextPurgeSucceeded)
        if finished { return true }
        if !results.isEmpty { return results.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Ends unexpected extra runs after the bounded assertions, so a repeat mutant cannot retain a continuation.
    func finishAll() {
        finished = true
        for waiter in waiters { waiter.resume(returning: true) }
        waiters.removeAll()
    }

    func release(succeeded: Bool) {
        if waiters.isEmpty {
            results.append(succeeded)
        } else {
            waiters.removeFirst().resume(returning: succeeded)
        }
    }
}

private actor ClaimBox {
    private(set) var hadClaim: Bool?
    func set(_ value: Bool) { hadClaim = value }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor private final class Finished {
    var results: [Bool] = []
    var stateAtFinish: (Bool, Bool)?

    func wait(count: Int = 1) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while results.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(results.count >= count, "the cleanup finished")
    }
}
