import AppleSecurityCore
import Foundation

/// In-memory Keychain for tests that need a working session store.
final class MemoryKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? {
        lock.withLock { storage[item] }
    }

    func setData(_ data: Data, for item: AppleKeychainItem) throws {
        lock.withLock { storage[item] = data }
    }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws {
        lock.withLock { _ = storage.removeValue(forKey: item) }
    }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}

/// Keychain that refuses every call, for tests that must never reach saved credentials.
struct DenyingKeychainStore: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? { throw CocoaError(.userCancelled) }
    func setData(_ data: Data, for item: AppleKeychainItem) throws { throw CocoaError(.userCancelled) }
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { throw CocoaError(.userCancelled) }
    func removeData(for item: AppleKeychainItem) throws { throw CocoaError(.userCancelled) }
    func removeAllData(service: String) throws { throw CocoaError(.userCancelled) }
}
