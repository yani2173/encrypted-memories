import Foundation
import Security

/// Accessibility policies used by Encrypted Memories' device-local secrets.
public enum AppleKeychainAccessibility: Sendable, Hashable {
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly

    fileprivate var securityValue: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    /// The class of a stored item, or nil for a class this app never writes.
    fileprivate init?(securityValue: String) {
        let known: [Self] = [.whenUnlockedThisDeviceOnly, .afterFirstUnlockThisDeviceOnly]
        guard let match = known.first(where: { $0.securityValue as String == securityValue }) else { return nil }
        self = match
    }
}

/// Complete identity and protection policy for one generic-password item.
public struct AppleKeychainItem: Sendable, Hashable {
    public let service: String
    public let account: String
    public let accessibility: AppleKeychainAccessibility

    public init(
        service: String,
        account: String,
        accessibility: AppleKeychainAccessibility
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
    }
}

public enum AppleSecurityOperation: String, Sendable, Equatable {
    case read
    case add
    case update
    case delete
}

/// Typed Security.framework failure. The OSStatus is retained for diagnostics without exposing item data.
public struct AppleSecurityError: Error, LocalizedError, Sendable, Equatable {
    public let operation: AppleSecurityOperation
    public let status: OSStatus

    public init(operation: AppleSecurityOperation, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Apple Security \(operation.rawValue) failed: \(detail)"
    }
}

/// Shared byte-level Keychain contract. Feature stores own encoding only; this contract owns every SecItem call.
public protocol AppleKeychainStoring: Sendable {
    func data(for item: AppleKeychainItem) throws -> Data?
    func setData(_ data: Data, for item: AppleKeychainItem) throws
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data
    func removeData(for item: AppleKeychainItem) throws
    func removeAllData(service: String) throws
    /// The class of the stored item, or nil when no item exists or the store cannot tell.
    func accessibility(for item: AppleKeychainItem) throws -> AppleKeychainAccessibility?
}

extension AppleKeychainStoring {
    /// A store that cannot report the class returns nil, so no migration ever writes through it.
    public func accessibility(for item: AppleKeychainItem) throws -> AppleKeychainAccessibility? { nil }
}

struct SecurityItemCopyResult: Sendable {
    let status: OSStatus
    let data: Data?
    /// The `kSecAttrAccessible` value of an attribute query.
    var accessible: String? = nil
}

protocol SecurityItemCalling: Sendable {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemSecurityItemClient: SecurityItemCalling {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let attributes = result as? [String: Any]
        return SecurityItemCopyResult(
            status: status, data: result as? Data, accessible: attributes?[kSecAttrAccessible as String] as? String)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// The single Data Protection Keychain transport for macOS, iOS, and iPadOS.
public struct SystemAppleKeychainStore: AppleKeychainStoring {
    private let security: any SecurityItemCalling

    public init() {
        self.init(security: SystemSecurityItemClient())
    }

    init(security: any SecurityItemCalling) {
        self.security = security
    }

    public func data(for item: AppleKeychainItem) throws -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw AppleSecurityError(operation: .read, status: errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw AppleSecurityError(operation: .read, status: result.status)
        }
    }

    public func setData(_ data: Data, for item: AppleKeychainItem) throws {
        let query = baseQuery(item)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: item.accessibility.securityValue,
        ]
        let updateStatus = security.update(query, attributes: attributes)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = security.add(add)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecDuplicateItem {
                let retryStatus = security.update(query, attributes: attributes)
                guard retryStatus == errSecSuccess else {
                    throw AppleSecurityError(operation: .update, status: retryStatus)
                }
                return
            }
            throw AppleSecurityError(operation: .add, status: addStatus)
        default:
            throw AppleSecurityError(operation: .update, status: updateStatus)
        }
    }

    public func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        if let existing = try self.data(for: item) { return existing }

        var add = baseQuery(item)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = item.accessibility.securityValue
        let status = security.add(add)
        if status == errSecSuccess { return data }
        if status == errSecDuplicateItem, let winner = try self.data(for: item) { return winner }
        throw AppleSecurityError(operation: .add, status: status)
    }

    public func removeData(for item: AppleKeychainItem) throws {
        let status = security.delete(baseQuery(item))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleSecurityError(operation: .delete, status: status)
        }
    }

    /// Removes every generic-password item in an app-owned service, regardless of account. Full logout
    /// uses this to sweep keys left by older accounts as well as the currently authenticated one.
    public func removeAllData(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = security.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleSecurityError(operation: .delete, status: status)
        }
    }

    /// Reads only the attributes of the item, never its data.
    public func accessibility(for item: AppleKeychainItem) throws -> AppleKeychainAccessibility? {
        var query = baseQuery(item)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            return result.accessible.flatMap(AppleKeychainAccessibility.init(securityValue:))
        case errSecItemNotFound:
            return nil
        default:
            throw AppleSecurityError(operation: .read, status: result.status)
        }
    }

    private func baseQuery(_ item: AppleKeychainItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
