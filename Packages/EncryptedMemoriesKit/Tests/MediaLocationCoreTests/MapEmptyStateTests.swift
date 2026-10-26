import PhotosCore
import Testing

@testable import MediaLocationCore

@Suite struct MapEmptyStateTests {
    private static let phases: [PhotoLocationScanProgress.Phase] = [.idle, .scanning, .completed, .failed]

    @Test func offlineWinsOverEveryScanPhase() {
        for phase in Self.phases {
            let progress = PhotoLocationScanProgress(phase: phase, scanned: 3, total: 9)
            #expect(MapEmptyState(isOnline: false, progress: progress) == .offline)
        }
    }

    @Test func anOnlineMapShowsTheStateOfTheScan() {
        let idle = PhotoLocationScanProgress(phase: .idle)
        let completed = PhotoLocationScanProgress(phase: .completed, scanned: 9, total: 9)
        let failed = PhotoLocationScanProgress(phase: .failed, scanned: 2, total: 9, failed: 2)
        #expect(MapEmptyState(isOnline: true, progress: idle) == .idle)
        #expect(MapEmptyState(isOnline: true, progress: completed) == .completed)
        #expect(MapEmptyState(isOnline: true, progress: failed) == .failed)
    }

    @Test func aScanningMapCarriesItsCounts() {
        let progress = PhotoLocationScanProgress(phase: .scanning, scanned: 12, total: 480)
        #expect(MapEmptyState(isOnline: true, progress: progress) == .scanning(scanned: 12, total: 480))
        let started = PhotoLocationScanProgress(phase: .scanning)
        #expect(MapEmptyState(isOnline: true, progress: started) == .scanning(scanned: 0, total: 0))
    }

    @Test func onlyAFailedScanOffersToTryAgain() {
        let states: [MapEmptyState] = [.offline, .scanning(scanned: 1, total: 2), .failed, .completed, .idle]
        for state in states {
            #expect(state.offersRetry == (state == .failed))
        }
    }
}
