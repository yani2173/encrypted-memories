/// Identifies automatic mobile account refreshes for request diagnostics and in-flight sharing.
public enum ProtonAccountInfoRequestCause: Sendable {
    case foregroundActivation
    case visibleSettings

    public func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        let cause: ProtonRequestCause =
            self == .foregroundActivation ? .accountForeground : .accountSettings
        return try await ProtonRequestContext.$cause.withValue(cause) {
            try await operation()
        }
    }
}
