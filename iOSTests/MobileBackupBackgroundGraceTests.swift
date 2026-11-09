import Foundation
import PhotosCore
import Testing
import UIKit
import UploadCore

@testable import EncryptedMemoriesMobile
@testable import PhotoLibraryBackupAdapter

@MainActor @Suite(.serialized) struct MobileBackupBackgroundGraceTests {
    @Test func aProcessingWindowKeepsItsAdoptedPassWhenTheShortGraceExpires() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        let controller = fixture.controller
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: controller)
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        attempt.work = Task { _ = await attempt.run(controller: controller) }
        try await fixture.waitUntil { attempt.runID != nil }
        let runID = try #require(controller.activeExecutionRunID)

        system.expire()

        #expect(!controller.isRunnerStopPendingForTesting, "the long window still owns this pass")
        #expect(controller.activeExecutionRunID == runID)
        #expect(system.ended == [system.identifier], "the short assertion still ends")
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }

    @Test func withoutAProcessingWindowTheShortGraceStillStopsItsPass() async throws {
        let fixture = try Fixture()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        let controller = fixture.controller
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: controller)
        let runID = try #require(controller.activeExecutionRunID)

        system.expire()

        #expect(controller.isRunnerStopPendingForTesting)
        #expect(controller.runnerStopRunIDForTesting == runID)
        #expect(system.ended == [system.identifier])
        fixture.scan.release()
        await fixture.close()
    }

    @Test func aFinishedProcessingWindowReleasesItsProtection() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        let runID = try #require(attempt.runID)
        #expect(protection.isProtected(owner: fixture.controller, runID: runID))
        fixture.scan.release()
        await attempt.work?.value
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        #expect(attempt.runID == nil)
        await fixture.close()
    }

    @Test func anExpiredProcessingWindowReleasesProtectionBeforeItsHeldScanEnds() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        let runID = try #require(attempt.runID)
        attempt.expire()
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        #expect(fixture.controller.runnerStopRunIDForTesting == runID)
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }

    @Test func aCancelledProcessingWaitReleasesProtectionBeforeItsHeldScanEnds() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        let runID = try #require(attempt.runID)
        attempt.work?.cancel()
        _ = await fixture.waitFor { !protection.isProtected(owner: fixture.controller, runID: runID) }
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        grace.protectActiveRun(controller: fixture.controller)
        system.expire()
        #expect(fixture.controller.runnerStopRunIDForTesting == runID)
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }

    @Test func completionReleasesItsTokenExactlyOnce() async throws {
        try await checkExactRelease(.completed)
    }

    @Test func expirationReleasesItsTokenExactlyOnce() async throws {
        try await checkExactRelease(.expired)
    }

    @Test func cancellationReleasesItsTokenExactlyOnce() async throws {
        try await checkExactRelease(.cancelled)
    }

    @Test func endingOneOfTwoWindowsDoesNotStopTheOthersAdoptedPass() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let releases = ReleaseCounts()
        releases.observe(protection)
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let first = PhotoBackupProcessingAttempt(protection: protection)
        let second = PhotoBackupProcessingAttempt(protection: protection)
        var firstEnded = false
        first.work = Task {
            _ = await first.run(controller: fixture.controller)
            firstEnded = true
        }
        second.work = Task { _ = await second.run(controller: fixture.controller) }
        try await fixture.waitUntil { first.runID != nil && second.runID != nil }
        let runID = try #require(first.runID)
        first.expire()
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        #expect(protection.isProtected(owner: fixture.controller, runID: runID))
        _ = await fixture.waitFor { firstEnded }
        #expect(firstEnded, "expiration ends the adopted wait before the held scan ends")
        second.expire()
        #expect(fixture.controller.runnerStopRunIDForTesting == runID)
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        fixture.scan.release()
        await first.work?.value
        await second.work?.value
        let cleanupEnded = await fixture.waitFor {
            first.cancellationReleaseEndedForTesting && second.cancellationReleaseEndedForTesting
        }
        #expect(cleanupEnded, "both queued cancellation cleanups must finish before counting")
        releases.expectExactlyOnce(tokenCount: 2)
        await fixture.close()
    }

    @Test func aRefreshScanNeverProtectsAnUploadPassFromTheShortGrace() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        let scan = Task {
            await fixture.controller.backgroundRefreshScan { runID in
                attempt.noteRefreshRun(controller: fixture.controller, runID: runID)
            }
        }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        let runID = try #require(attempt.runID)
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        grace.protectActiveRun(controller: fixture.controller)
        system.expire()
        #expect(fixture.controller.runnerStopRunIDForTesting == runID)
        fixture.scan.release()
        _ = await scan.value
        await fixture.close()
    }

    @Test func anOldGraceCallbackCannotStopARenewedGraceForTheSamePass() async throws {
        let fixture = try Fixture()
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let system = GraceSystem()
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        grace.protectActiveRun(controller: fixture.controller)
        let old = try #require(system.expiration)
        grace.end()
        grace.protectActiveRun(controller: fixture.controller)
        old()
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        #expect(system.ended.count == 1)
        system.expire()
        #expect(fixture.controller.isRunnerStopPendingForTesting)
        #expect(system.ended.count == 2)
        fixture.scan.release()
        await fixture.close()
    }

    @Test func aWindowExpiredBeforeItsFirstJobStartsNoPass() async throws {
        try await checkEndBeforeFirstJob(cancelled: false)
    }

    @Test func aWindowCancelledBeforeItsFirstJobStartsNoPass() async throws {
        try await checkEndBeforeFirstJob(cancelled: true)
    }

    private func checkEndBeforeFirstJob(cancelled: Bool) async throws {
        let fixture = try Fixture()
        let attempt = PhotoBackupProcessingAttempt(protection: BackgroundBackupRunProtection())
        if !cancelled { attempt.expire() }
        var ended = false
        let work = Task {
            _ = await attempt.run(controller: fixture.controller)
            ended = true
        }
        if cancelled { work.cancel() }
        _ = await fixture.waitFor { ended || fixture.scan.started }
        #expect(fixture.controller.activeExecutionRunID == nil)
        #expect(!fixture.scan.started)
        fixture.scan.release()
        fixture.controller.stopSync()
        await work.value
        await fixture.close()
    }

    @Test func anExpiredAdoptingWindowKeepsThePassNowVisibleInTheForeground() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        var ended = false
        attempt.work = Task {
            _ = await attempt.run(controller: fixture.controller)
            ended = true
        }
        try await fixture.waitUntil { attempt.runID != nil }
        fixture.runtime.update { $0.executionOpportunity = .foregroundActive }
        attempt.expire()
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        _ = await fixture.waitFor { ended }
        #expect(ended, "expiration ends the adopted wait before the visible pass ends")
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }

    @Test func anExpiredResumedAdmissionKeepsTheOtherWindowsProtection() async throws {
        try await checkEndedResumedAdmission(cancelled: false)
    }

    @Test func aCancelledResumedAdmissionKeepsTheOtherWindowsProtection() async throws {
        try await checkEndedResumedAdmission(cancelled: true)
    }

    private func checkEndedResumedAdmission(cancelled: Bool) async throws {
        let fixture = try Fixture(networkKnown: false)
        let protection = BackgroundBackupRunProtection()
        let first = PhotoBackupProcessingAttempt(protection: protection)
        let second = PhotoBackupProcessingAttempt(protection: protection)
        var admissions = 0
        func beforeAdmission(_ attempt: PhotoBackupProcessingAttempt, runID: String) {
            admissions += 1
            if admissions == 2 {
                #expect(protection.isProtected(owner: fixture.controller, runID: runID))
                if cancelled { attempt.work?.cancel() } else { attempt.expire() }
            }
        }
        first.beforeRunAdmissionForTesting = { [weak first] runID in
            if let first { beforeAdmission(first, runID: runID) }
        }
        second.beforeRunAdmissionForTesting = { [weak second] runID in
            if let second { beforeAdmission(second, runID: runID) }
        }
        first.work = Task { _ = await first.run(controller: fixture.controller) }
        second.work = Task { _ = await second.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.controller.deferredStartWaiterCountForTesting == 2 }
        fixture.runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
        try await fixture.waitUntil { admissions == 2 }
        let runID = try #require(fixture.controller.activeExecutionRunID)
        #expect(first.runID == runID && second.runID == runID)
        #expect(!fixture.controller.isRunnerStopPendingForTesting, "the other resumed window still protects this run")
        #expect(protection.isProtected(owner: fixture.controller, runID: runID))
        fixture.scan.release()
        await first.work?.value
        await second.work?.value
        first.beforeRunAdmissionForTesting = nil
        second.beforeRunAdmissionForTesting = nil
        await fixture.close()
    }

    @Test func aDeferredRunKeepsItsWindowBeforeTheWaitingAdmissionResumes() async throws {
        try await checkDeferredRunBeforeAdmission(launchResumeWaits: true)
    }

    @Test func aWindowsOwnDeferredRunKeepsItsWindowBeforeTheWaitingAdmissionResumes() async throws {
        try await checkDeferredRunBeforeAdmission(launchResumeWaits: false)
    }

    /// With the launch resume waiting, the window runs the automatic pass; without it, the window's own deferred pass.
    private func checkDeferredRunBeforeAdmission(launchResumeWaits: Bool) async throws {
        let fixture = try Fixture(networkKnown: false)
        let protection = BackgroundBackupRunProtection()
        let releases = ReleaseCounts()
        releases.observe(protection)
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        var reachedAdmission = false
        var expiredBeforeAdmission = false
        var exposedRunID: String?
        var ended = false
        attempt.beforeRunAdmissionForTesting = { _ in reachedAdmission = true }
        fixture.controller.idleTimerHook = { active in
            guard active else { return }
            exposedRunID = fixture.controller.activeExecutionRunID
            expiredBeforeAdmission = !reachedAdmission
            #expect(exposedRunID != nil, "the real controller has admitted and locked its run")
            #expect(expiredBeforeAdmission, "the waiting admission has not resumed")
            #expect(!attempt.didExpire && attempt.work?.isCancelled == false, "the long window is still valid")
            #expect(fixture.controller.executionOwnerForTesting == .iOSBackgroundTask)
            #expect(
                exposedRunID.map { protection.isProtected(owner: fixture.controller, runID: $0) } == true,
                "the controller and run must already have protection at their first exposure")
            grace.protectActiveRun(controller: fixture.controller)
            #expect(system.starts == 0, "the window's run begins no short grace")
            system.expire()
            #expect(
                !fixture.controller.isRunnerStopPendingForTesting,
                "grace must not stop the run before its waiting processing admission resumes")
        }
        if launchResumeWaits { fixture.startAutomaticPass() }
        attempt.work = Task {
            _ = await attempt.run(controller: fixture.controller)
            ended = true
        }
        let waiting = await fixture.waitFor { fixture.controller.deferredStartWaiterCountForTesting == 1 }
        #expect(waiting, "the real controller must register the processing waiter before the path arrives")
        fixture.runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
        let admitted = await fixture.waitFor { reachedAdmission }
        #expect(admitted, "the resumed admission must be observed before cleanup")
        #expect(expiredBeforeAdmission)
        #expect(exposedRunID != nil)
        #expect(system.starts == 0 && system.ended.isEmpty, "a run that a window holds begins no short grace")
        fixture.scan.release()
        let completed = await fixture.waitFor { ended }
        #expect(completed, "the released run must end before cleanup")
        if !completed {
            attempt.work?.cancel()
            fixture.controller.stopSync()
        }
        await attempt.work?.value
        releases.expectExactlyOnce(tokenCount: 1)
        attempt.beforeRunAdmissionForTesting = nil
        fixture.controller.idleTimerHook = nil
        await fixture.close()
    }

    @Test func aDirectlyStartedRunKeepsItsWindowWhenTheGraceExpiresAtOnce() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        var stoppedAtTheHook: Bool?
        fixture.controller.idleTimerHook = { active in
            guard active, stoppedAtTheHook == nil else { return }
            // A refused assertion reports its expiration; here it comes before the window's admission returns.
            grace.protectActiveRun(controller: fixture.controller)
            system.expire()
            stoppedAtTheHook = fixture.controller.isRunnerStopPendingForTesting
        }
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        #expect(stoppedAtTheHook == false, "grace must not stop the window's own run at its first exposure")
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        fixture.scan.release()
        await attempt.work?.value
        fixture.controller.idleTimerHook = nil
        await fixture.close()
    }

    @Test func aWindowThatTakesOverAPassEndsItsShortGrace() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 1, "the automatic pass began its short grace before the window came")
        let attempt = PhotoBackupProcessingAttempt(protection: protection, endShortGrace: { grace.end() })
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { attempt.runID != nil }
        #expect(system.ended == [system.identifier], "the window carries the pass now and ends the short grace")
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }

    /// #998: after the pass it took over, the window runs the person's pending retry as a pass of its own. The window
    /// carries that run too, so the run begins no short grace that could stop it and use the retry up.
    @Test func aWindowProtectsTheRetryPassItRunsAfterThePassItTookOver() async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 1, "the automatic pass began its short grace before the window came")
        fixture.controller.markManualWiFiRetryPendingForTesting()

        let attempt = PhotoBackupProcessingAttempt(protection: protection, endShortGrace: { grace.end() })
        var runIDs: [String] = []
        attempt.beforeRunAdmissionForTesting = { runIDs.append($0) }
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { runIDs.count == 1 }
        // From here the app's hook reports each pass start to the short grace, as in production.
        fixture.controller.idleTimerHook = { active in
            if active { grace.protectActiveRun(controller: fixture.controller) } else { grace.end() }
        }
        fixture.scan.release()
        await attempt.work?.value

        #expect(runIDs.count == 2, "the window took the pass over, then ran its own pass for the retry")
        #expect(runIDs.first != runIDs.last)
        #expect(system.starts == 1, "the window's retry pass begins no short grace")
        #expect(!fixture.controller.isManualWiFiRetryPendingForTesting, "the window's pass carried the retry")
        await fixture.close()
    }

    @Test func anUnprotectedPassStillBeginsItsShortGrace() async throws {
        let fixture = try Fixture()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 1, "a pass without a window keeps its short grace")
        fixture.scan.release()
        await fixture.close()
    }

    @Test func anExpiringWaitingWindowTakesNoProtectionWhenItsPassStarts() async throws {
        let fixture = try Fixture(networkKnown: false)
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        var protectedAtTheHook: Bool?
        fixture.controller.idleTimerHook = { active in
            guard active, protectedAtTheHook == nil, let runID = fixture.controller.activeExecutionRunID else { return }
            protectedAtTheHook = protection.isProtected(owner: fixture.controller, runID: runID)
        }
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.controller.deferredStartWaiterCountForTesting == 1 }
        // The path reaches the state before its observer. The window expires, and its pass starts in the same turn,
        // before the window's queued cancellation removes its wait.
        fixture.runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
        attempt.expire()
        fixture.controller.mobileDataSettingDidChange()
        #expect(protectedAtTheHook == false, "an expired window must not protect the pass that starts for it")
        let runID = try #require(fixture.controller.activeExecutionRunID)
        _ = await fixture.waitFor { fixture.controller.runnerStopRunIDForTesting != nil }
        #expect(fixture.controller.runnerStopRunIDForTesting == runID, "the expired window stops its pass")
        fixture.scan.release()
        await attempt.work?.value
        fixture.controller.idleTimerHook = nil
        await fixture.close()
    }

    @Test func thePassStartedAfterTheFirstNetworkPathKeepsItsLongWindow() async throws {
        let fixture = try Fixture(networkKnown: false)
        let protection = BackgroundBackupRunProtection()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: protection)
        fixture.controller.idleTimerHook = { active in
            if active { grace.protectActiveRun(controller: fixture.controller) }
        }
        fixture.startAutomaticPass()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { fixture.controller.deferredStartWaiterCountForTesting == 1 }
        fixture.runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
        try await fixture.waitUntil { fixture.scan.started && attempt.runID != nil }
        #expect(fixture.controller.executionOwnerForTesting == .iOSBackgroundTask)
        #expect(system.starts == 0, "the window's run begins no short grace")
        system.expire()
        #expect(!fixture.controller.isRunnerStopPendingForTesting)
        fixture.scan.release()
        await attempt.work?.value
        fixture.controller.idleTimerHook = nil
        await fixture.close()
    }

    @Test func expiryDuringAdmissionStopsTheRunBeforeItGetsProtection() async throws {
        try await checkEndDuringAdmission(cancelled: false)
    }

    @Test func cancellationDuringAdmissionStopsTheRunBeforeItGetsProtection() async throws {
        try await checkEndDuringAdmission(cancelled: true)
    }

    @Test func expiryBeforeTheWaitingAdmissionResumesStopsTheRun() async throws {
        try await checkEndDuringAdmission(cancelled: false, waitsForThePath: true)
    }

    @Test func cancellationBeforeTheWaitingAdmissionResumesStopsTheRun() async throws {
        try await checkEndDuringAdmission(cancelled: true, waitsForThePath: true)
    }

    /// With `waitsForThePath`, the window already holds its protection when it ends, before its admission resumes.
    private func checkEndDuringAdmission(cancelled: Bool, waitsForThePath: Bool = false) async throws {
        let fixture = try Fixture(networkKnown: !waitsForThePath)
        let protection = BackgroundBackupRunProtection()
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        fixture.controller.idleTimerHook = { active in
            guard active else { return }
            if cancelled { attempt.work?.cancel() } else { attempt.didExpire = true }
        }
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        if waitsForThePath {
            try await fixture.waitUntil { fixture.controller.deferredStartWaiterCountForTesting == 1 }
            fixture.runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
        }
        _ = await fixture.waitFor { fixture.controller.runnerStopRunIDForTesting != nil }
        let runID = try #require(attempt.runID)
        #expect(fixture.controller.runnerStopRunIDForTesting == runID)
        #expect(!protection.isProtected(owner: fixture.controller, runID: runID))
        fixture.scan.release()
        await attempt.work?.value
        fixture.controller.idleTimerHook = nil
        await fixture.close()
    }

    @Test func graceStartsOnlyOnceAndEndsOnlyItsCurrentAssertion() async throws {
        let fixture = try Fixture()
        let system = GraceSystem()
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 0, "a controller without a run needs no assertion")
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        grace.protectActiveRun(controller: fixture.controller)
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 1)
        grace.end(generation: UUID())
        #expect(system.ended.isEmpty)
        grace.end()
        grace.end()
        #expect(system.ended == [system.identifier])
        fixture.scan.release()
        await fixture.close()
    }

    @Test func aRejectedAssertionCanBeRequestedAgain() async throws {
        let fixture = try Fixture()
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let system = GraceSystem()
        system.identifier = .invalid
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        grace.protectActiveRun(controller: fixture.controller)
        grace.end()
        #expect(system.ended.isEmpty)
        system.identifier = UIBackgroundTaskIdentifier(rawValue: 48)
        grace.protectActiveRun(controller: fixture.controller)
        #expect(system.starts == 2)
        system.expire()
        #expect(fixture.controller.isRunnerStopPendingForTesting)
        #expect(system.ended == [system.identifier])
        fixture.scan.release()
        await fixture.close()
    }

    @Test func aRejectedAssertionsOwnCallbackStillStopsAnUnprotectedPass() async throws {
        let fixture = try Fixture()
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let system = GraceSystem()
        system.identifier = .invalid
        let grace = system.makeGrace(protection: BackgroundBackupRunProtection())
        grace.protectActiveRun(controller: fixture.controller)
        system.expire()
        #expect(fixture.controller.isRunnerStopPendingForTesting)
        #expect(system.ended.isEmpty, "an assertion that was not granted must not be ended")
        fixture.scan.release()
        await fixture.close()
    }

    private enum ProtectionEnd {
        case completed, expired, cancelled
    }

    private func checkExactRelease(_ end: ProtectionEnd) async throws {
        let fixture = try Fixture()
        let protection = BackgroundBackupRunProtection()
        let releases = ReleaseCounts()
        releases.observe(protection)
        fixture.startAutomaticPass()
        let scanStarted = await fixture.waitFor { fixture.scan.started }
        #expect(scanStarted, "the control pass must hold its scan")
        let attempt = PhotoBackupProcessingAttempt(protection: protection)
        var ended = false
        attempt.work = Task {
            _ = await attempt.run(controller: fixture.controller)
            ended = true
        }
        let bound = await fixture.waitFor { releases.heldTokens.count == 1 }
        #expect(bound, "one real protection token must be acquired")
        let runID = fixture.controller.activeExecutionRunID
        let expectsCancellationCleanup: Bool
        switch end {
        case .completed:
            expectsCancellationCleanup = false
            fixture.scan.release()
        case .expired:
            expectsCancellationCleanup = true
            attempt.expire()
        case .cancelled:
            expectsCancellationCleanup = true
            attempt.work?.cancel()
        }
        if expectsCancellationCleanup {
            let cleanupEnded = await fixture.waitFor { attempt.cancellationReleaseEndedForTesting }
            #expect(cleanupEnded, "observe the queued cancellation cleanup before the final count")
            #expect(runID.map { !protection.isProtected(owner: fixture.controller, runID: $0) } == true)
        }
        fixture.scan.release()
        let completed = await fixture.waitFor { ended }
        #expect(completed, "the released work must end before the final join")
        if !completed {
            attempt.work?.cancel()
            fixture.controller.stopSync()
        }
        await attempt.work?.value
        releases.expectExactlyOnce(tokenCount: 1)
        await fixture.close()
    }

    @MainActor private final class ReleaseCounts {
        var heldTokens: [UUID] = []
        private var releaseAttempts: [UUID: Int] = [:]

        func observe(_ protection: BackgroundBackupRunProtection) {
            protection.onHoldForTesting = { [weak self] token in self?.heldTokens.append(token) }
            protection.onReleaseAttemptForTesting = { [weak self] token in
                guard let self else { return }
                self.releaseAttempts[token, default: 0] += 1
            }
        }

        func expectExactlyOnce(tokenCount: Int) {
            #expect(heldTokens.count == tokenCount)
            #expect(Set(heldTokens).count == tokenCount)
            let expected = heldTokens.reduce(into: [UUID: Int]()) { $0[$1] = 1 }
            #expect(releaseAttempts == expected, "each acquired token must reach release exactly once")
        }
    }

    @MainActor private final class GraceSystem {
        var identifier = UIBackgroundTaskIdentifier(rawValue: 47)
        var starts = 0
        var expiration: (@MainActor @Sendable () -> Void)?
        var ended: [UIBackgroundTaskIdentifier] = []

        func makeGrace(protection: BackgroundBackupRunProtection) -> PhotoBackupBackgroundGrace {
            PhotoBackupBackgroundGrace(
                protection: protection,
                beginTask: {
                    self.starts += 1
                    self.expiration = $0
                    return self.identifier
                },
                endTask: { self.ended.append($0) })
        }

        func expire() { expiration?() }
    }

    private final class HeldScan: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        var started: Bool { lock.withLock { didStart } }

        func hold() async {
            await withCheckedContinuation { continuation in
                let released = lock.withLock {
                    didStart = true
                    if isReleased { return true }
                    self.continuation = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }

        func release() {
            let waiter = lock.withLock {
                isReleased = true
                defer { continuation = nil }
                return continuation
            }
            waiter?.resume()
        }
    }

    @MainActor private struct Fixture {
        let controller: PhotoLibraryBackupController
        let scan = HeldScan()
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let runtime: LibraryRuntimeState

        init(networkKnown: Bool = true) throws {
            suite = "background-grace-" + UUID().uuidString
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                if networkKnown { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            }
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
                runtimeSignals: BackupRuntimeSignalSource(
                    current: { [runtime] in BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: false) },
                    updates: { [runtime] in runtime.updates() }),
                // The tests deliver the first path themselves; a slow runner must not reach the bounded wait.
                firstNetworkPathWait: .seconds(600))
            configuration.currentAccessState = { .full }
            let backend = Backend()
            controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: backend, uploader: backend)
            controller.setEnabledForTesting()
            controller.replaceScanForTesting { [scan] in await scan.hold() }
        }

        /// Starts the automatic pass of the person's visit, then leaves the foreground. In the background only a window
        /// starts a pass (#832), so a pass that the short grace protects started while a scene was in the foreground.
        /// Before the first network path the pass waits for it instead.
        func startAutomaticPass() {
            runtime.update { $0.executionOpportunity = .foregroundActive }
            controller.syncNow()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let ready = await waitFor(condition)
            try #require(ready, "fixture must reach the held pass")
        }

        func waitFor(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { await Task.yield() }
            return condition()
        }

        func close() async {
            scan.release()
            await controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Backend: PhotoUploading, UploadIdentityResolving {
        let capabilities = UploadBackendCapabilities(
            canUpload: false, supportsCancel: true, supportsPauseResume: false, supportsResumeAcrossRelaunch: false)
        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            throw CancellationError()
        }
        func upload(
            _ request: PhotoUploadRequest, onProgress: @escaping @Sendable (UploadProgress) -> Void
        ) async throws -> PhotoUID { throw CancellationError() }
        func cancel(token: UUID) async {}
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw CancellationError()
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String,
            remoteLinkID: String
        ) async throws { throw CancellationError() }
    }

    @Test func expirationCancelsTheAdoptedWorkSynchronously() async throws {
        let fixture = try Fixture()
        fixture.startAutomaticPass()
        try await fixture.waitUntil { fixture.scan.started }
        let attempt = PhotoBackupProcessingAttempt(protection: BackgroundBackupRunProtection())
        attempt.work = Task { _ = await attempt.run(controller: fixture.controller) }
        try await fixture.waitUntil { attempt.runID != nil }
        attempt.expire()
        #expect(attempt.work?.isCancelled == true, "expiration cancels its work before returning")
        fixture.scan.release()
        await attempt.work?.value
        await fixture.close()
    }
}
