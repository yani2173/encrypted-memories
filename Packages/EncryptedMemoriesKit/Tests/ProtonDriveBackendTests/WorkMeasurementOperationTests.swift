import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite struct WorkMeasurementOperationTests {
    @Test func phaseMeasurementKeepsSequentialOperationsAndTheirResult() async throws {
        let clock = OperationMeasurementClock()
        let collector = SupportWorkMeasurements(now: { clock.value })
        let order = OperationMeasurementOrder()
        let result = await WorkMeasurementOperation.run(.timelineLoad, collector: collector) { pass in
            pass?.setTimelineSource(.sdkCache)
            let first = await WorkMeasurementOperation.phase(.enumeration, pass: pass) {
                order.append(1)
                clock.advance(.seconds(5))
                return 40
            }
            let second = await WorkMeasurementOperation.phase(.tags, pass: pass) {
                order.append(2)
                clock.advance(.seconds(10))
                return 2
            }
            return first + second
        }
        #expect(result == 42)
        #expect(order.values == [1, 2])
        let state = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.timelineLoad.rawValue]
        let sample = try #require(state.samples.first)
        #expect(state.started == 1 && state.completed == 1 && state.inProgress == 0)
        #expect(sample.enumerationClass == 2)
        #expect(sample.tagsClass == 2)
        #expect(sample.totalClass == 3)
        #expect(sample.timelineSource == 1)
        #expect(sample.outcome == 0)
    }

    @Test func failedEnumerationIsMeasuredAndTagsDoNotBecomeAZeroDuration() async throws {
        let clock = OperationMeasurementClock()
        let collector = SupportWorkMeasurements(now: { clock.value })
        do {
            let _: Int = try await WorkMeasurementOperation.run(.timelineLoad, collector: collector) { pass in
                try await WorkMeasurementOperation.phase(.enumeration, pass: pass) { () async throws -> Int in
                    clock.advance(.seconds(2))
                    throw MeasurementProbeError.rejected
                }
            }
            Issue.record("the original error must propagate")
        } catch { #expect(error as? MeasurementProbeError == .rejected) }
        let sample = try #require(
            collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.timelineLoad.rawValue].samples
                .first)
        #expect(sample.enumerationClass == 1)
        #expect(sample.tagsClass == -1)
        #expect(sample.totalClass == 1)
        #expect(sample.outcome == 2)
    }

    @Test func failureKeepsEarlierSuccessesAndCancellationIsNotSuccess() async throws {
        let collector = SupportWorkMeasurements()
        do {
            let _: Int = try await WorkMeasurementOperation.run(.eventUpdate, collector: collector) { pass in
                pass?.record(.unlockSucceeded)
                throw MeasurementProbeError.rejected
            }
            Issue.record("the original error must propagate")
        } catch { #expect(error as? MeasurementProbeError == .rejected) }
        do {
            let _: Int = try await WorkMeasurementOperation.run(.viewerRead, collector: collector) { pass in
                pass?.record(.nodeCallsStarted)
                throw CancellationError()
            }
            Issue.record("cancellation must propagate")
        } catch { #expect(error is CancellationError) }
        let snapshot = collector.workMeasurementSupportSnapshot()
        #expect(snapshot.passes[SupportMeasurementKind.eventUpdate.rawValue].counters[0] == 1)
        #expect(snapshot.passes[SupportMeasurementKind.eventUpdate.rawValue].samples.last?.outcome == 2)
        #expect(snapshot.passes[SupportMeasurementKind.viewerRead.rawValue].samples.last?.outcome == 3)
        #expect(snapshot.passes[SupportMeasurementKind.viewerRead.rawValue].counters[5] == 0)
    }

    @Test func aPartialRepairIsNotOverwrittenByItsNormalReturn() async throws {
        let collector = SupportWorkMeasurements()
        let result = await WorkMeasurementOperation.run(.lineageRepair, collector: collector) { pass in
            pass?.record(.decryptSucceeded)
            pass?.finish(.partial)
            return 7
        }
        #expect(result == 7)
        let state = collector.workMeasurementSupportSnapshot().passes[SupportMeasurementKind.lineageRepair.rawValue]
        #expect(state.completed == 1 && state.samples.count == 1)
        #expect(state.samples.first?.outcome == 1)
        #expect(state.counters[1] == 1)
    }

    @Test func noCollectorKeepsTheOriginalOperation() async {
        let result = await WorkMeasurementOperation.run(.indexRebuild, collector: nil) { pass in
            #expect(pass == nil)
            return 42
        }
        #expect(result == 42)
    }

    @Test(
        "a late cancel flag keeps a built result and only turns a failure into cancelled",
        arguments: [
            (SupportMeasurementOutcome.success, true, SupportMeasurementOutcome.success),
            (SupportMeasurementOutcome.partial, true, SupportMeasurementOutcome.partial),
            (SupportMeasurementOutcome.failure, true, SupportMeasurementOutcome.cancelled),
            (SupportMeasurementOutcome.failure, false, SupportMeasurementOutcome.failure),
        ]
    ) func lateCancellationKeepsBuiltResults(
        recorded: SupportMeasurementOutcome, taskCancelled: Bool, resolved: SupportMeasurementOutcome
    ) {
        #expect(
            WorkMeasurementOperation.resolveOutcome(recorded: recorded, taskCancelled: taskCancelled) == resolved)
    }
}

private enum MeasurementProbeError: Error, Equatable { case rejected }

private final class OperationMeasurementClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Duration.zero
    var value: Duration { lock.withLock { current } }
    func advance(_ amount: Duration) { lock.withLock { current += amount } }
}

private final class OperationMeasurementOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var values: [Int] { lock.withLock { recorded } }
    func append(_ value: Int) { lock.withLock { recorded.append(value) } }
}
