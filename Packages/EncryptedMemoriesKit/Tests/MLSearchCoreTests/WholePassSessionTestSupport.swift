import PhotosCore

@testable import MLSearchCore

/// A session double that implements only a whole-pass `index`. A quantum whose caller has already
/// withdrawn permission gets an idle outcome and nothing is indexed.
protocol WholePassSession: MLSmartSearchSession {
    func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome
}

extension WholePassSession {
    func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        guard shouldContinue() else {
            return MLIndexPassOutcome(
                report: MLIndexBatchReport(),
                ranToCompletion: false,
                newPermanentFailures: [],
                progress: MLIndexProgress(
                    phase: .idle,
                    descriptor: descriptor,
                    totalAssets: assets.count
                )
            )
        }
        return await index(assets, observer: observer)
    }
}
