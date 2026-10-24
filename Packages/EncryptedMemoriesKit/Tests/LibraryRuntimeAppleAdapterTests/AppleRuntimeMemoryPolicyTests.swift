import PhotosCore
import XCTest

@testable import LibraryRuntimeAppleAdapter

@MainActor
final class AppleRuntimeMemoryPolicyTests: XCTestCase {
    func testPreservesStrongestPressureSignalInEveryOpportunity() {
        for opportunity: LibraryExecutionOpportunity in [
            .foregroundActive, .foregroundInactive, .backgroundPermitted, .suspended,
        ] {
            for pressure: MemoryConditions.Pressure in [.normal, .warning, .critical] {
                XCTAssertEqual(conditions(opportunity, pressure: pressure).pressure, pressure)
                XCTAssertEqual(conditions(opportunity, pressure: pressure, warningLatched: true).pressure, .critical)
                for warningLatched in [false, true] {
                    XCTAssertEqual(
                        AppleRuntimeMemoryPolicy.pressure(
                            dispatchPressure: pressure,
                            memoryWarningLatched: warningLatched
                        ),
                        conditions(opportunity, pressure: pressure, warningLatched: warningLatched).pressure
                    )
                }
            }
        }
    }

    func testHealthyBackgroundPermitsAutomaticWorkWithReducedCaches() async throws {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let governor = MemoryPressureGovernor(runtimeState: state)
        governor.update(conditions(.backgroundPermitted))
        XCTAssertEqual(governor.tier, .reduced)
        XCTAssertEqual(state.snapshot().memoryPressure, .normal)
        XCTAssertEqual(state.snapshot().memoryHeadroom, .healthy)

        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        for workload: LibraryHeavyWorkload in [.mlIndexing, .backupMaterialization] {
            let request = LibraryWorkRequest(workload: workload, intent: .automatic)
            let budget = await coordinator.budget(for: request)
            XCTAssertTrue(budget.isAdmitted, "Healthy background work must progress: \(workload)")
            guard budget.isAdmitted else { continue }
            let decision = try await coordinator.withHeavyPermit(request) { $0.continuationDecision() }
            XCTAssertEqual(decision, .continueWork)
        }
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.permitsAcquired, 2)
        XCTAssertEqual(metrics.permitsReleased, 2)
    }

    func testBackgroundPressurePreservesAutomaticAndInteractiveAdmissionRules() {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let governor = MemoryPressureGovernor(runtimeState: state)
        let policy = LibraryResourcePolicy()
        let requests = [
            LibraryWorkRequest(workload: .mlIndexing, intent: .automatic),
            LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic),
            LibraryWorkRequest(workload: .backupMaterialization, intent: .userInitiated),
            LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small),
        ]
        let cases: [(MemoryConditions, [Bool])] = [
            (conditions(.backgroundPermitted), [true, true, true, true]),
            (conditions(.backgroundPermitted, pressure: .warning), [false, false, true, true]),
            (conditions(.backgroundPermitted, thermal: .serious), [false, false, true, true]),
            (conditions(.backgroundPermitted, pressure: .critical), [false, false, false, false]),
            (conditions(.backgroundPermitted, warningLatched: true), [false, false, false, false]),
            (conditions(.backgroundPermitted, thermal: .critical), [false, false, false, false]),
            (conditions(.backgroundPermitted, lowPower: true), [false, true, true, true]),
        ]
        for (signals, expected) in cases {
            governor.update(signals)
            let admitted = requests.map { policy.budget(for: $0, snapshot: state.snapshot()).isAdmitted }
            XCTAssertEqual(admitted, expected, "Signals: \(signals)")
        }
        governor.update(conditions(.suspended))
        state.update { $0.executionOpportunity = .suspended }
        XCTAssertEqual(governor.tier, .reduced)
        XCTAssertTrue(requests.allSatisfy { !policy.budget(for: $0, snapshot: state.snapshot()).isAdmitted })
    }

    func testBackgroundCacheReductionDoesNotPreemptButRealPressureDoes() async throws {
        let state = LibraryRuntimeState()
        let governor = MemoryPressureGovernor(runtimeState: state)
        governor.update(conditions(.foregroundActive))
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let background = conditions(.backgroundPermitted)
        let warning = conditions(.backgroundPermitted, pressure: .warning)
        try await coordinator.withHeavyPermit(LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)) { lease in
            await MainActor.run {
                state.update { $0.executionOpportunity = .backgroundPermitted }
                governor.update(background)
            }
            XCTAssertEqual(lease.continuationDecision(), .continueWork)
            await MainActor.run { governor.update(warning) }
            XCTAssertEqual(lease.continuationDecision(), .yield(.memoryPressure))
        }
    }

    func testSceneLedgerReducesCachesOnlyAfterLastForegroundSceneLeaves() {
        var ledger = LibrarySceneActivityLedger()
        let governor = MemoryPressureGovernor()
        governor.update(conditions(ledger.update(sceneID: "first", phase: .active)))
        governor.update(conditions(ledger.update(sceneID: "second", phase: .background)))
        XCTAssertEqual(governor.tier, .normal)
        governor.update(conditions(ledger.update(sceneID: "first", phase: .inactive)))
        XCTAssertEqual(governor.tier, .normal)
        governor.update(conditions(ledger.update(sceneID: "first", phase: .background)))
        XCTAssertEqual(governor.tier, .reduced)
        XCTAssertEqual(governor.conditions.pressure, .normal)
        governor.update(conditions(ledger.remove(sceneID: "second")))
        XCTAssertEqual(governor.tier, .reduced)
        governor.update(conditions(ledger.update(sceneID: "first", phase: .active)))
        XCTAssertEqual(governor.tier, .normal)
    }

    private func conditions(
        _ opportunity: LibraryExecutionOpportunity,
        pressure: MemoryConditions.Pressure = .normal,
        warningLatched: Bool = false,
        thermal: MemoryConditions.Thermal = .nominal,
        lowPower: Bool = false
    ) -> MemoryConditions {
        AppleRuntimeMemoryPolicy.conditions(
            dispatchPressure: pressure,
            memoryWarningLatched: warningLatched,
            executionOpportunity: opportunity,
            thermal: thermal,
            lowPowerMode: lowPower
        )
    }
}
