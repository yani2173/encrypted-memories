import Testing

@testable import TimelineCore

@Suite struct UploadRefreshSignalTrackerTests {
    private func tracker(passIsRunning: Bool = false) -> UploadRefreshSignalTracker {
        UploadRefreshSignalTracker(backupRevision: 0, manualRevision: 0, passIsRunning: passIsRunning)
    }

    @Test func aBackupUploadDuringARunningPassWaitsForTheInterval() {
        var signals = tracker(passIsRunning: true)
        let outcome = signals.observe(backupRevision: 1, manualRevision: 0, passIsRunning: true)
        #expect(outcome == .init(refresh: .backupUpload(passIsRunning: true), passEnded: false))
    }

    @Test func aManualUploadRefreshesAtOnce() {
        var signals = tracker(passIsRunning: true)
        let outcome = signals.observe(backupRevision: 0, manualRevision: 1, passIsRunning: true)
        #expect(outcome == .init(refresh: .manualUpload, passEnded: false))
    }

    @Test func oneChangeWithBothSignalsIsServedByTheImmediateRefresh() {
        var signals = tracker(passIsRunning: true)
        let outcome = signals.observe(backupRevision: 4, manualRevision: 2, passIsRunning: true)
        #expect(outcome.refresh == .manualUpload)
        let next = signals.observe(backupRevision: 4, manualRevision: 2, passIsRunning: true)
        #expect(next == .init(refresh: nil, passEnded: false), "Both signals are consumed together")
    }

    @Test func theEndOfAPassIsReportedOnceEvenWithoutAnUpload() {
        var signals = tracker(passIsRunning: true)
        #expect(
            signals.observe(backupRevision: 0, manualRevision: 0, passIsRunning: false)
                == .init(refresh: nil, passEnded: true))
        #expect(
            signals.observe(backupRevision: 0, manualRevision: 0, passIsRunning: false)
                == .init(refresh: nil, passEnded: false))
    }

    @Test func aBackupUploadThatArrivesAfterThePassEndedKnowsThatNoPassRuns() {
        var signals = tracker(passIsRunning: false)
        let outcome = signals.observe(backupRevision: 1, manualRevision: 0, passIsRunning: false)
        #expect(outcome == .init(refresh: .backupUpload(passIsRunning: false), passEnded: false))
    }

    @Test func theLastUploadAndTheEndOfThePassInOneChangeReportBoth() {
        var signals = tracker(passIsRunning: true)
        let outcome = signals.observe(backupRevision: 1, manualRevision: 0, passIsRunning: false)
        #expect(outcome == .init(refresh: .backupUpload(passIsRunning: false), passEnded: true))
    }

    @Test func aFirstRevisionAfterNoBackupControllerCountsAsASignal() {
        var signals = UploadRefreshSignalTracker(backupRevision: nil, manualRevision: nil, passIsRunning: false)
        let outcome = signals.observe(backupRevision: 0, manualRevision: nil, passIsRunning: false)
        #expect(outcome.refresh == .backupUpload(passIsRunning: false), "The earlier code refreshed here as well")
    }

    @Test func aPassThatStartsIsNoEnd() {
        var signals = tracker(passIsRunning: false)
        let outcome = signals.observe(backupRevision: 0, manualRevision: 0, passIsRunning: true)
        #expect(outcome == .init(refresh: nil, passEnded: false))
    }
}
