import Foundation

/// The stable runtime-failure classes shared by every Smart Search host.
///
/// The categories describe what a lifecycle can do next. They do not persist as lifecycle state:
/// a permanent model failure is blocked for the current actor session, while a new process may
/// retry after an updated install, OS, or runtime becomes available.
public enum MLRuntimeFailureCategory: String, Codable, Equatable, Hashable, Sendable {
    // Permanent model or contract failures.
    case missingModel
    case incompatibleModel
    case invalidOutputSchema
    case invalidStaticInputContract

    // Retryable runtime conditions.
    case network
    case temporaryResource
    case retryableRuntimeState

    /// An unclassified error uses the safe retryable fallback.
    case unknown

    public var disposition: MLRuntimeFailureDisposition {
        switch self {
        case .missingModel, .incompatibleModel, .invalidOutputSchema, .invalidStaticInputContract:
            return .permanent
        case .network, .temporaryResource, .retryableRuntimeState:
            return .transient
        case .unknown:
            return .unknown
        }
    }
}

/// The lifecycle action permitted by a typed runtime failure.
public enum MLRuntimeFailureDisposition: String, Codable, Equatable, Hashable, Sendable {
    case permanent
    case transient
    /// The failure is not understood. Callers must preserve the safe retryable fallback.
    case unknown

    public var isRetryable: Bool { self != .permanent }
}

/// A runtime failure with an explicit Core-owned retry disposition.
public struct MLRuntimeFailure: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let category: MLRuntimeFailureCategory
    /// The category is authoritative. Callers cannot construct an internally inconsistent retry policy.
    public var disposition: MLRuntimeFailureDisposition { category.disposition }
    /// Diagnostic detail for logs. It must not contain model bytes, credentials, or user content.
    public let debugDescription: String

    public init(category: MLRuntimeFailureCategory, debugDescription: String = "") {
        self.category = category
        self.debugDescription = debugDescription
    }

    public var isRetryable: Bool { disposition.isRetryable }
    public var isPermanent: Bool { disposition == .permanent }

    public var description: String {
        if debugDescription.isEmpty { return category.rawValue }
        return "\(category.rawValue): \(debugDescription)"
    }
}
