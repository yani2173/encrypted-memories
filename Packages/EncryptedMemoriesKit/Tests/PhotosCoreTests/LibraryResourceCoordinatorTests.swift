import XCTest

@testable import PhotosCore

final class LibraryResourceCoordinatorTests: XCTestCase {
    func testRuntimeStatePublishesNewestAndGenerationResetClearsFeatureDemand() async throws {
        let state = LibraryRuntimeState()
        let stream = state.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.generation, 0)

        state.update {
            $0.hasVisibleMediaDemand = true
            $0.activeUserTransferCount = 3
        }
        let updated = await iterator.next()
        XCTAssertEqual(updated?.activeUserTransferCount, 3)
        let noOp = state.update { _ in }
        XCTAssertEqual(noOp, updated)

        let reset = state.beginNewGeneration()
        XCTAssertEqual(reset.generation, 1)
        XCTAssertFalse(reset.hasVisibleMediaDemand)
        XCTAssertEqual(reset.activeUserTransferCount, 0)
    }

    func testPolicyMatrixProtectsCriticalAndVisibleWork() {
        let policy = LibraryResourcePolicy()
        let automatic = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let interactive = LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small)

        var snapshot = LibraryRuntimeSnapshot(thermalLevel: .critical)
        XCTAssertFalse(policy.budget(for: interactive, snapshot: snapshot).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(hasVisibleMediaDemand: true)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertTrue(policy.budget(for: interactive, snapshot: snapshot).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(thermalLevel: .serious)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertEqual(policy.budget(for: interactive, snapshot: snapshot).maxItemsPerQuantum, 1)
        XCTAssertFalse(
            policy.budget(
                for: LibraryWorkRequest(workload: .mlModelLoading, intent: .userInitiated, memoryClass: .large),
                snapshot: snapshot
            ).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(isLowPowerMode: true)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .backupHashing, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
    }

    func testRequestWithoutDemandPreservesLegacyBudget() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(workload: .mlIndexing, intent: .automatic),
            snapshot: LibraryRuntimeSnapshot()
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 1)
        XCTAssertEqual(budget.maxItemsPerQuantum, 2)
        XCTAssertNil(budget.maximumWallTime)
        XCTAssertEqual(budget.reason, .nominal)
    }

    func testAutomaticMLDemandReceivesRequestedNominalEnvelope() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(
                workload: .mlIndexing,
                intent: .automatic,
                demand: LibraryWorkDemand(
                    maximumInternalParallelism: 3,
                    maximumItemsPerQuantum: 32,
                    maximumWallTime: .seconds(2)
                )
            ),
            snapshot: LibraryRuntimeSnapshot()
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 3)
        XCTAssertEqual(budget.maxItemsPerQuantum, 32)
        XCTAssertEqual(budget.maximumWallTime, .seconds(2))
        XCTAssertEqual(budget.reason, .nominal)
    }

    func testFairPressureRestrictsAutomaticMLDemandToOneAssetAndHalfSecond() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(
                workload: .mlIndexing,
                intent: .automatic,
                demand: LibraryWorkDemand(
                    maximumInternalParallelism: 3,
                    maximumItemsPerQuantum: 128,
                    maximumWallTime: .seconds(2)
                )
            ),
            snapshot: LibraryRuntimeSnapshot(thermalLevel: .fair)
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 1)
        XCTAssertEqual(budget.maxItemsPerQuantum, 1)
        XCTAssertEqual(budget.maximumWallTime, .milliseconds(500))
        XCTAssertEqual(budget.reason, .fairPressure)
    }

    func testLeaseYieldsToEveryLiveSafetySignal() async throws {
        let cases:
            [(
                LibraryWorkYieldReason,
                @Sendable (LibraryRuntimeState) -> Void
            )] = [
                (.visibleDemand, { state in state.update { $0.hasVisibleMediaDemand = true } }),
                (.userInteraction, { state in state.update { $0.hasActiveUserInteraction = true } }),
                (.lowPowerMode, { state in state.update { $0.isLowPowerMode = true } }),
                (.thermalPressure, { state in state.update { $0.thermalLevel = .serious } }),
                (.memoryPressure, { state in state.update { $0.memoryPressure = .warning } }),
                (.memoryPressure, { state in state.update { $0.memoryHeadroom = .constrained } }),
                (.executionSuspended, { state in state.update { $0.executionOpportunity = .suspended } }),
                (.generationChanged, { state in _ = state.beginNewGeneration() }),
            ]
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)

        for (expected, mutate) in cases {
            let state = LibraryRuntimeState()
            let coordinator = LibraryResourceCoordinator(runtimeState: state)
            let decision = try await coordinator.withHeavyPermit(request) { lease in
                XCTAssertTrue(lease.shouldContinue())
                mutate(state)
                return lease.continuationDecision()
            }
            XCTAssertEqual(decision, .yield(expected))
        }
    }

    func testLeaseUsesInjectedMonotonicDeadline() async throws {
        let clock = TestMonotonicClock()
        let coordinator = LibraryResourceCoordinator(
            runtimeState: LibraryRuntimeState(),
            monotonicNow: { clock.now() }
        )
        let request = LibraryWorkRequest(
            workload: .mlIndexing,
            intent: .automatic,
            demand: LibraryWorkDemand(
                maximumInternalParallelism: 3,
                maximumItemsPerQuantum: 32,
                maximumWallTime: .seconds(2)
            )
        )

        let decisions = try await coordinator.withHeavyPermit(request) { lease in
            let before = lease.continuationDecision()
            clock.advance(by: 1_999_999_999)
            let inside = lease.continuationDecision()
            clock.advance(by: 1)
            let expired = lease.continuationDecision()
            return [before, inside, expired]
        }

        XCTAssertEqual(
            decisions,
            [
                .continueWork,
                .continueWork,
                .yield(.timeSliceCompleted),
            ])
    }

    func testHigherPriorityWaiterPreemptsAutomaticLeaseAtBoundary() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let holderGate = AsyncGate()
        let leaseBox = LeaseBox()
        let automatic = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
            ) { lease in
                await leaseBox.store(lease)
                await holderGate.wait()
            }
        }
        let lease = await leaseBox.waitForLease()
        XCTAssertTrue(lease.shouldContinue())

        let interactive = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .mlInference,
                    intent: .interactive,
                    memoryClass: .small
                )
            ) { _ in true }
        }
        let didPreempt = await waitUntil {
            lease.continuationDecision() == .yield(.higherPriorityWork)
        }
        XCTAssertTrue(didPreempt)

        await holderGate.open()
        try await automatic.value
        let interactiveCompleted = try await interactive.value
        XCTAssertTrue(interactiveCompleted)
    }

    func testExpiredVisibleDemandReleasesWaitingModelLoadPermit() async throws {
        let state = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(hasVisibleMediaDemand: true)
        )
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        let permit = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .mlModelLoading,
                    intent: .automatic,
                    memoryClass: .large
                )
            ) { _ in true }
        }

        await Task.yield()
        let metricsWhileBlocked = await coordinator.metrics()
        XCTAssertEqual(metricsWhileBlocked.permitsAcquired, 0)

        state.update { $0.hasVisibleMediaDemand = false }
        let admitted = try await permit.value
        let finalMetrics = await coordinator.metrics()
        XCTAssertTrue(admitted)
        XCTAssertEqual(finalMetrics.permitsAcquired, 1)
        XCTAssertEqual(finalMetrics.permitsReleased, 1)
    }

    func testEnforcedCoordinatorAllowsOnlyOneHeavyPermit() async throws {
        // Backup preparation shares admission only in the foreground without pressure; everything else runs alone.
        let backup = LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
        let cases: [(LibraryWorkRequest, LibraryRuntimeSnapshot)] = [
            (LibraryWorkRequest(workload: .mlIndexing, intent: .automatic), LibraryRuntimeSnapshot()),
            (LibraryWorkRequest(workload: .videoDerivative, intent: .userInitiated), LibraryRuntimeSnapshot()),
            (backup, LibraryRuntimeSnapshot(isLowPowerMode: true)),
            (backup, LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted)),
            (backup, LibraryRuntimeSnapshot(memoryBudgetTier: .reduced)),
            (
                LibraryWorkRequest(workload: .backupMaterialization, intent: .userInitiated),
                LibraryRuntimeSnapshot(thermalLevel: .serious)
            ),
        ]

        for (request, snapshot) in cases {
            let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState(initial: snapshot))
            let counter = ActiveCounter()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await coordinator.withHeavyPermit(request) { _ in
                            await counter.enter()
                            try await Task.sleep(for: .milliseconds(5))
                            await counter.leave()
                        }
                    }
                }
                try await group.waitForAll()
            }
            let maximum = await counter.maximum()
            XCTAssertEqual(maximum, 1, "\(request.workload) in \(snapshot)")
            let metrics = await coordinator.metrics()
            XCTAssertEqual(metrics.permitsAcquired, 8)
            XCTAssertEqual(metrics.permitsReleased, 8)
            XCTAssertEqual(metrics.maximumConcurrentPermits, 1)
        }
    }

    func testBackupPreparationSharesAdmissionOnlyInTheForegroundWithoutPressure() {
        let policy = LibraryResourcePolicy()
        for intent in [LibraryWorkIntent.automatic, .userInitiated] {
            for workload in [LibraryHeavyWorkload.backupMaterialization, .backupHashing] {
                let request = LibraryWorkRequest(workload: workload, intent: intent, memoryClass: .large)
                func permits(_ snapshot: LibraryRuntimeSnapshot) -> Int {
                    policy.budget(for: request, snapshot: snapshot).concurrentPermits
                }
                let pressured = intent == .userInitiated ? 1 : 0
                XCTAssertEqual(permits(LibraryRuntimeSnapshot()), 3, "\(workload) \(intent)")
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(executionOpportunity: .foregroundInactive)), 3)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(thermalLevel: .fair)), 2)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(thermalLevel: .serious)), pressured)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(memoryPressure: .warning)), pressured)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(memoryHeadroom: .constrained)), pressured)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(memoryBudgetTier: .reduced)), 1)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(isLowPowerMode: true)), 1)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted)), 1)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(hasVisibleMediaDemand: true)), 0)
                XCTAssertEqual(permits(LibraryRuntimeSnapshot(hasActiveUserInteraction: true)), 0)
            }
        }
        let exclusiveWorkloads: [LibraryHeavyWorkload] = [
            .mlModelLoading, .mlInference, .mlIndexing, .cryptoPreparation, .videoDerivative,
        ]
        for workload in exclusiveWorkloads {
            let request = LibraryWorkRequest(workload: workload, intent: .userInitiated)
            XCTAssertEqual(
                policy.budget(for: request, snapshot: LibraryRuntimeSnapshot()).concurrentPermits, 1, "\(workload)")
        }
    }

    func testThreeBackupPermitsRunTogetherWhileAFourthWaits() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let counter = ActiveCounter()
        let gate = AsyncGate()
        let permits = (0..<4).map { index in
            Task {
                let workload: LibraryHeavyWorkload = index.isMultiple(of: 2) ? .backupMaterialization : .backupHashing
                try await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: workload, intent: .automatic, memoryClass: .large)
                ) { _ in
                    await counter.enter()
                    await gate.wait()
                    await counter.leave()
                }
            }
        }

        let threeRun = await waitUntilYielding {
            let running = await counter.current()
            let waiting = await coordinator.waitingPermitCount
            return running == 3 && waiting == 1
        }
        XCTAssertTrue(threeRun, "three photos prepare at once and the fourth waits for a free permit")

        await gate.open()
        for permit in permits { try await permit.value }
        let maximum = await counter.maximum()
        XCTAssertEqual(maximum, 3)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.permitsAcquired, 4)
        XCTAssertEqual(metrics.permitsReleased, 4)
        XCTAssertEqual(metrics.maximumConcurrentPermits, 3)
    }

    func testQueuedExclusiveWorkStopsNewBackupPermitsAndNeverRunsBesideThem() async throws {
        let exclusiveRequests = [
            LibraryWorkRequest(workload: .mlIndexing, intent: .automatic),
            LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small),
        ]
        let backup = LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic, memoryClass: .large)

        for exclusive in exclusiveRequests {
            let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
            let runningBackups = ActiveCounter()
            let holderGate = AsyncGate()
            let holder = Task {
                try await coordinator.withHeavyPermit(backup) { _ in
                    await runningBackups.enter()
                    await holderGate.wait()
                    await runningBackups.leave()
                }
            }
            await holderGate.waitUntilEntered()

            let exclusiveWork = Task {
                try await coordinator.withHeavyPermit(exclusive) { _ in await runningBackups.current() }
            }
            let exclusiveQueued = await waitUntilYielding { await coordinator.waitingPermitCount == 1 }
            XCTAssertTrue(exclusiveQueued, "\(exclusive.workload) waits for the running backup permit")

            let laterBackup = Task {
                try await coordinator.withHeavyPermit(backup) { _ in
                    await runningBackups.enter()
                    await runningBackups.leave()
                }
            }
            let laterQueued = await waitUntilYielding { await coordinator.waitingPermitCount == 2 }
            XCTAssertTrue(laterQueued, "a free shared permit must not let backup pass \(exclusive.workload)")

            await holderGate.open()
            try await holder.value
            let backupsBesideExclusiveWork = try await exclusiveWork.value
            XCTAssertEqual(backupsBesideExclusiveWork, 0)
            try await laterBackup.value
            let metrics = await coordinator.metrics()
            XCTAssertEqual(metrics.permitsAcquired, 3)
            XCTAssertEqual(metrics.permitsReleased, 3)
            XCTAssertEqual(metrics.maximumConcurrentPermits, 1)
        }
    }

    func testHigherPriorityWaiterPreemptsEveryLowerPrioritySharedPermit() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let holderGate = AsyncGate()
        let leases = LeaseBox()
        let backup = LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic)
        let holders = (0..<2).map { _ in
            Task {
                try await coordinator.withHeavyPermit(backup) { lease in
                    await leases.store(lease)
                    await holderGate.wait()
                }
            }
        }
        let held = await leases.waitForLeases(count: 2)
        XCTAssertTrue(held.allSatisfy { $0.shouldContinue() }, "a permit that shares admission preempts no one")

        let interactive = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small)
            ) { _ in true }
        }
        let didPreempt = await waitUntil {
            held.allSatisfy { $0.continuationDecision() == .yield(.higherPriorityWork) }
        }
        XCTAssertTrue(didPreempt, "every running permit of lower priority yields at its next boundary")

        await holderGate.open()
        for holder in holders { try await holder.value }
        let interactiveCompleted = try await interactive.value
        XCTAssertTrue(interactiveCompleted)
    }

    func testCancelledWaiterDoesNotLeakAdmission() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let gate = AsyncGate()
        // Exclusive work, so the second permit waits instead of sharing admission.
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let holder = Task {
            try await coordinator.withHeavyPermit(request) { _ in await gate.wait() }
        }
        await gate.waitUntilEntered()

        let cancelled = Task {
            try await coordinator.withHeavyPermit(request) { _ in XCTFail("cancelled waiter ran") }
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        await gate.open()
        try await holder.value
        let completed = try await coordinator.withHeavyPermit(request) { _ in true }
        XCTAssertTrue(completed)
    }

    func testRecoveryHysteresisRequiresStableDelay() async throws {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .critical))
        let recoveryGate = RecoveryDelayGate()
        let coordinator = LibraryResourceCoordinator(
            runtimeState: state,
            recoveryDelay: .milliseconds(30),
            recoverySleep: { await recoveryGate.wait(for: $0) }
        )
        await coordinator.startObserving()
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let initiallyAdmitted = await coordinator.budget(for: request).isAdmitted
        XCTAssertFalse(initiallyAdmitted)

        state.update { $0.thermalLevel = .nominal }
        let requestedDelay = await recoveryGate.waitUntilEntered()
        XCTAssertEqual(requestedDelay, .milliseconds(30))
        let admittedDuringRecovery = await coordinator.budget(for: request).isAdmitted
        XCTAssertFalse(admittedDuringRecovery)

        await recoveryGate.open()
        let recovered = await waitUntilAsync {
            await coordinator.budget(for: request).isAdmitted
        }
        XCTAssertTrue(recovered)
    }

    func testFreedStorageSkipsTheRecoveryDelay() async {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(storagePressure: .critical))
        let coordinator = LibraryResourceCoordinator(runtimeState: state, recoveryDelay: .seconds(30))
        await coordinator.startObserving()
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let paused = await coordinator.budget(for: request)
        XCTAssertEqual(paused.reason, .storagePressure)

        // Storage levels already have their own hysteresis. Freed space must not wait another 30 seconds.
        state.update { $0.storagePressure = .low }
        let admitted = await waitUntilAsync { await coordinator.budget(for: request).isAdmitted }
        XCTAssertTrue(admitted)
    }

    func testCacheBudgetRecoveryDoesNotDelayForegroundWork() async {
        let state = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(memoryBudgetTier: .reduced, executionOpportunity: .backgroundPermitted)
        )
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        state.update {
            $0.executionOpportunity = .foregroundActive
            $0.memoryBudgetTier = .normal
        }
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let foregroundApplied = await waitUntilAsync {
            let budget = await coordinator.budget(for: request)
            return budget.isAdmitted && budget.memoryTier == .normal
        }
        XCTAssertTrue(foregroundApplied)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.recoveries, 0)
    }

    func testMemoryPressureRecoveryWaitsEvenWhenBackgroundCacheTierStaysReduced() async throws {
        let state = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(
                memoryPressure: .warning, memoryBudgetTier: .reduced, executionOpportunity: .backgroundPermitted
            )
        )
        let recoveryGate = RecoveryDelayGate()
        let coordinator = LibraryResourceCoordinator(
            runtimeState: state,
            recoveryDelay: .seconds(30),
            recoverySleep: { await recoveryGate.wait(for: $0) }
        )
        await coordinator.startObserving()
        state.update { $0.memoryPressure = .normal }
        let enteredRecovery = await waitUntilAsync { await recoveryGate.hasEntered() }
        XCTAssertTrue(enteredRecovery)
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let duringRecovery = await coordinator.budget(for: request)
        XCTAssertFalse(duringRecovery.isAdmitted)
        await recoveryGate.open()
        let recovered = await waitUntilAsync { await coordinator.budget(for: request).isAdmitted }
        XCTAssertTrue(recovered)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.recoveries, 1)
    }

    func testGenerationChangeRejectsAQueuedOldSessionPermit() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        let gate = AsyncGate()
        // Exclusive work, so the stale permit waits instead of sharing admission.
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let holder = Task {
            try await coordinator.withHeavyPermit(request) { _ in await gate.wait() }
        }
        await gate.waitUntilEntered()
        let stale = Task {
            try await coordinator.withHeavyPermit(request) { _ in XCTFail("stale session work ran") }
        }

        let queued = await waitUntilYielding { await coordinator.waitingPermitCount == 1 }
        XCTAssertTrue(queued, "stale permit was not queued")
        let generation = state.beginNewGeneration().generation
        let observed = await waitUntilYielding { await coordinator.observedGeneration == generation }
        XCTAssertTrue(observed, "coordinator did not observe the new generation")
        await gate.open()
        try await holder.value
        do {
            try await stale.value
            XCTFail("expected stale work cancellation")
        } catch is CancellationError {}
    }

    // MARK: - Work in an iOS background window

    func testTheBackgroundWorkloadsYieldToLowPowerModeAndTheCrawlToCriticalStorage() {
        let policy = LibraryResourcePolicy()
        let orderPass = LibraryBackgroundWorkTuning.orderPass
        let crawl = LibraryBackgroundWorkTuning.crawlBatch
        let window = LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted)
        XCTAssertTrue(policy.budget(for: orderPass, snapshot: window).isAdmitted)
        XCTAssertTrue(policy.budget(for: crawl, snapshot: window).isAdmitted)

        let lowPower = LibraryRuntimeSnapshot(isLowPowerMode: true, executionOpportunity: .backgroundPermitted)
        for request in [orderPass, crawl] {
            let budget = policy.budget(for: request, snapshot: lowPower)
            XCTAssertFalse(budget.isAdmitted, "\(request.workload)")
            XCTAssertEqual(budget.reason, .lowPowerMode, "\(request.workload)")
        }

        let fullStorage = LibraryRuntimeSnapshot(storagePressure: .critical, executionOpportunity: .backgroundPermitted)
        XCTAssertFalse(policy.budget(for: crawl, snapshot: fullStorage).isAdmitted, "the crawl fills the cache")
        XCTAssertTrue(policy.budget(for: orderPass, snapshot: fullStorage).isAdmitted, "the order pass writes little")
    }

    func testNextYieldWakesOnARuntimeChange() async throws {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let reason = try await coordinator.withHeavyPermit(LibraryBackgroundWorkTuning.orderPass) { lease in
            let waiting = Task { await lease.nextYield() }
            state.update { $0.executionOpportunity = .suspended }
            return await boundedValue(of: waiting)
        }
        XCTAssertEqual(reason, .some(.executionSuspended))
    }

    func testNextYieldWakesWhenABackupItemWaitsForThePermit() async throws {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let backupRan = AsyncTestSignal()
        let (reason, backup) = try await coordinator.withHeavyPermit(LibraryBackgroundWorkTuning.orderPass) {
            lease in
            let waiting = Task { await lease.nextYield() }
            // The backup item arrives only after the wait checked the lease once, so only the preemption can wake it.
            let checked = await waitFor { lease.yieldWaitEvaluations >= 1 }
            XCTAssertTrue(checked, "the wait checked the lease")
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in backupRan.fire() }
            }
            return (await boundedValue(of: waiting), backup)
        }
        XCTAssertEqual(reason, .some(.higherPriorityWork), "backup outranks background work")
        await awaitWindowEvent(backupRan, "the backup item after the release")
        await backup.value
    }

    func testNextYieldWakesAtTheEndOfTheTimeSlice() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let request = LibraryWorkRequest(
            workload: .mlIndexing, intent: .automatic,
            demand: LibraryWorkDemand(
                maximumInternalParallelism: 1, maximumItemsPerQuantum: 1, maximumWallTime: .milliseconds(50)))
        let reason = try await coordinator.withHeavyPermit(request) { lease in
            await boundedValue(of: Task { await lease.nextYield() })
        }
        XCTAssertEqual(reason, .some(.timeSliceCompleted))
    }

    func testNextYieldEndsWhenItsTaskIsCancelled() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let reason = try await coordinator.withHeavyPermit(LibraryBackgroundWorkTuning.orderPass) { lease in
            let waiting = Task { await lease.nextYield() }
            waiting.cancel()
            return await boundedValue(of: waiting)
        }
        XCTAssertEqual(reason, .some(nil), "a cancelled wait returns without a reason")
    }
}

private func waitUntilYielding(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

private actor AsyncGate {
    private var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RecoveryDelayGate {
    private var requestedDelay: Duration?
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hasEntered() -> Bool { requestedDelay != nil }

    func wait(for delay: Duration) async {
        requestedDelay = delay
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async -> Duration {
        while true {
            if let requestedDelay { return requestedDelay }
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor ActiveCounter {
    private var active = 0
    private var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() { active -= 1 }
    func current() -> Int { active }
    func maximum() -> Int { peak }
}

private actor LeaseBox {
    private var leases: [LibraryWorkLease] = []

    func store(_ lease: LibraryWorkLease) {
        leases.append(lease)
    }

    func waitForLease() async -> LibraryWorkLease {
        await waitForLeases(count: 1)[0]
    }

    func waitForLeases(count: Int) async -> [LibraryWorkLease] {
        while leases.count < count { await Task.yield() }
        return leases
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 { lock.withLock { value } }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await predicate()
}
