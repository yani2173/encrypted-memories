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
    let gate = CleanupGate()
    let cleanup: ProtonAuthStartupCleanup

    init() {
        let claims = claims
        let pending = pending
        let gate = gate
        cleanup = ProtonAuthStartupCleanup(
            claimPurge: {
                claims.value += 1
                return nil
            },
            isPurgePending: { pending.value > 0 },
            run: { _, plaintextPurgeSucceeded in await gate.run(plaintextPurgeSucceeded) })
    }
}

/// Holds each cleanup run until the test releases it with a result.
private actor CleanupGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var results: [Bool] = []
    private(set) var plaintextPurgeArguments: [Bool?] = []

    func run(_ plaintextPurgeSucceeded: Bool?) async -> Bool {
        plaintextPurgeArguments.append(plaintextPurgeSucceeded)
        if !results.isEmpty { return results.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
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
