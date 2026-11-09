import Foundation
import PhotosCore
import UploadCore

/// Observes one existing operation. Errors, results, cancellation and scheduling remain owned by its caller.
enum WorkMeasurementOperation {
    static func phase<Value: Sendable>(
        _ phase: SupportMeasurementPhase, pass: SupportWorkMeasurementPass?,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        let start = pass?.instant()
        defer { pass?.endPhase(phase, since: start) }
        return try await operation()
    }

    static func run<Value: Sendable>(
        _ kind: SupportMeasurementKind, collector: SupportWorkMeasurements?,
        operation: @Sendable (SupportWorkMeasurementPass?) async throws -> Value
    ) async rethrows -> Value {
        let pass = collector?.begin(kind)
        do {
            let value = try await operation(pass)
            pass?.finish(.success)
            return value
        } catch {
            pass?.finish(UploadError.isCancellation(error) ? .cancelled : .failure)
            throw error
        }
    }

    /// Resolves a pass outcome when the task cancel flag may have landed after the work already
    /// completed: a pass that built a full or partial result keeps it, while a failure becomes
    /// cancelled because no usable result exists.
    static func resolveOutcome(
        recorded: SupportMeasurementOutcome, taskCancelled: Bool
    ) -> SupportMeasurementOutcome {
        guard taskCancelled else { return recorded }
        switch recorded {
        case .success, .partial: return recorded
        case .failure, .cancelled: return .cancelled
        }
    }
}
