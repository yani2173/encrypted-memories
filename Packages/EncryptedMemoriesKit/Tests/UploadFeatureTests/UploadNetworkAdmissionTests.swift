import Foundation
import Testing

@testable import UploadCore

/// Uploads that avoid expensive networks and uploads that may use them never run at the same time.
@Suite("Network admission of uploads")
struct UploadNetworkAdmissionTests {
    @Test func uploadsOfOneKindRunSideBySideAndTheOtherKindWaitsForThem() async throws {
        let admission = UploadNetworkAdmission()
        let first = try await admission.reserve(allowsExpensiveNetwork: false)
        let second = try await admission.reserve(allowsExpensiveNetwork: false)

        let started = Flag()
        let person = Task {
            let reservation = try await admission.reserve(allowsExpensiveNetwork: true)
            started.set()
            return reservation
        }
        try await waitUntil { admission.waitingCount == 1 }
        first.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!started.isSet, "an upload of the other kind still runs")

        second.release()
        let reservation = try await value(of: person)
        #expect(reservation.isActive)
        #expect(reservation.allowsExpensiveNetwork)
        reservation.release()
    }

    @Test func aWaitingUploadOfThePersonHoldsBackNewBackupUploads() async throws {
        let admission = UploadNetworkAdmission()
        let backup = try await admission.reserve(allowsExpensiveNetwork: false)
        let person = Task { try await admission.reserve(allowsExpensiveNetwork: true) }
        try await waitUntil { admission.waitingCount == 1 }

        let laterBackup = Task { try await admission.reserve(allowsExpensiveNetwork: false) }
        try await waitUntil { admission.waitingCount == 2 }
        #expect(admission.waitingCount == 2, "the later backup upload waits behind the person's upload")

        backup.release()
        let personReservation = try await value(of: person)
        try await Task.sleep(for: .milliseconds(100))
        #expect(admission.waitingCount == 1, "the later backup upload still waits while the person's upload runs")

        personReservation.release()
        let laterReservation = try await value(of: laterBackup)
        #expect(!laterReservation.allowsExpensiveNetwork)
        laterReservation.release()
    }

    @Test func aCancelledWaitEndsAtOnceAndKeepsNoPlace() async throws {
        let admission = UploadNetworkAdmission()
        let backup = try await admission.reserve(allowsExpensiveNetwork: false)
        let person = Task { try await admission.reserve(allowsExpensiveNetwork: true) }
        try await waitUntil { admission.waitingCount == 1 }
        let laterBackup = Task { try await admission.reserve(allowsExpensiveNetwork: false) }
        try await waitUntil { admission.waitingCount == 2 }

        person.cancel()
        await #expect(throws: CancellationError.self) { try await value(of: person) }
        // The cancelled upload of the person no longer holds the later backup upload back.
        let laterReservation = try await value(of: laterBackup)
        #expect(admission.waitingCount == 0)

        backup.release()
        laterReservation.release()
        let next = try await admission.reserve(allowsExpensiveNetwork: true)
        #expect(next.isActive, "no place stays taken")
        next.release()
    }

    @Test func aWaitThatIsCancelledBeforeItStartsThrowsAndTakesNoPlace() async throws {
        let admission = UploadNetworkAdmission()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await admission.reserve(allowsExpensiveNetwork: false)
        }
        await #expect(throws: CancellationError.self) { try await value(of: cancelled) }
        let person = try await admission.reserve(allowsExpensiveNetwork: true)
        #expect(person.isActive, "the cancelled wait took no place")
        person.release()
    }

    @Test func aSecondReleaseFreesNothingMore() async throws {
        let admission = UploadNetworkAdmission()
        let first = try await admission.reserve(allowsExpensiveNetwork: false)
        let second = try await admission.reserve(allowsExpensiveNetwork: false)
        first.release()
        first.release()
        #expect(!first.isActive)

        let person = Task { try await admission.reserve(allowsExpensiveNetwork: true) }
        try await waitUntil { admission.waitingCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(admission.waitingCount == 1, "the second backup upload still runs")
        second.release()
        try await value(of: person).release()
    }

    @Test func aReservationBelongsToItsAdmission() async throws {
        let admission = UploadNetworkAdmission()
        let other = UploadNetworkAdmission()
        let reservation = try await other.reserve(allowsExpensiveNetwork: true)
        #expect(!admission.issued(reservation))
        #expect(other.issued(reservation))
        reservation.release()
    }

    /// The task's value, or a failure after `limit`: a wait that never ends cancels the task instead of hanging.
    private func value<T: Sendable>(of task: Task<T, any Error>, within limit: Duration = .seconds(5)) async throws -> T
    {
        let timeout = Task {
            try await Task.sleep(for: limit)
            task.cancel()
        }
        defer { timeout.cancel() }
        return try await task.value
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition(), clock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "the condition holds within 5 s")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
