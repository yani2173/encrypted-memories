import Foundation
import Security
import Testing

@testable import AppleSecurityCore

@Suite("Shared Apple security transport")
struct AppleKeychainStoreTests {
    @Test func queryKeepsTheServiceAndImplicitAccessGroupContract() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let item = AppleKeychainItem(
            service: "at.oncloud.encryptedmemories.session", account: "default",
            accessibility: .whenUnlockedThisDeviceOnly)
        _ = try store.data(for: item)
        let query = try #require(security.lastReadQuery)
        #expect(query[kSecAttrService as String] as? String == item.service)
        #expect(query[kSecAttrAccount as String] as? String == "default")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func protectedItemUpdatesWithoutDeleteAndAdd() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let item = uniqueItem("update")

        try store.setData(Data("first".utf8), for: item)
        try store.setData(Data("second".utf8), for: item)

        #expect(try store.data(for: item) == Data("second".utf8))
        #expect(security.addCount == 1)
        #expect(security.deleteCount == 0)
    }

    @Test func dataOrInsertKeepsFirstDurableValue() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let item = uniqueItem("insert")

        let first = try store.dataOrInsert(Data("first".utf8), for: item)
        let second = try store.dataOrInsert(Data("second".utf8), for: item)

        #expect(first == Data("first".utf8))
        #expect(second == first)
        #expect(try store.data(for: item) == first)
        #expect(security.addCount == 1)
    }

    @Test func servicePurgeRemovesEveryProtectedAccount() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let service = "at.oncloud.encryptedmemories.security-tests.purge.\(UUID().uuidString)"
        let first = AppleKeychainItem(service: service, account: "first", accessibility: .whenUnlockedThisDeviceOnly)
        let second = AppleKeychainItem(service: service, account: "second", accessibility: .whenUnlockedThisDeviceOnly)
        security.seed(Data("protected".utf8), item: first, dataProtection: true)
        security.seed(Data("second".utf8), item: second, dataProtection: true)

        try store.removeAllData(service: service)

        #expect(security.storedData(for: first, dataProtection: true) == nil)
        #expect(security.storedData(for: second, dataProtection: true) == nil)
    }

    @Test func secureRandomReturnsRequestedByteCount() throws {
        #expect(try AppleSecureRandom.data(count: 32).count == 32)
        #expect(try AppleSecureRandom.data(count: 0).isEmpty)
    }

    private func uniqueItem(_ purpose: String) -> AppleKeychainItem {
        AppleKeychainItem(
            service: "at.oncloud.encryptedmemories.security-tests.\(purpose).\(UUID().uuidString)",
            account: "default",
            accessibility: .whenUnlockedThisDeviceOnly
        )
    }
}

private final class MemorySecurityItemClient: SecurityItemCalling, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String
        let dataProtection: Bool
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]
    private var adds = 0
    private var deletes = 0
    private var readQuery: [String: Any]?

    var lastReadQuery: [String: Any]? { lock.withLock { readQuery } }

    var addCount: Int { lock.withLock { adds } }
    var deleteCount: Int { lock.withLock { deletes } }

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        lock.withLock {
            readQuery = query
            guard let key = key(from: query), let data = storage[key] else {
                return SecurityItemCopyResult(status: errSecItemNotFound, data: nil)
            }
            return SecurityItemCopyResult(status: errSecSuccess, data: data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard let key = key(from: attributes), let data = attributes[kSecValueData as String] as? Data else {
                return errSecParam
            }
            guard storage[key] == nil else { return errSecDuplicateItem }
            storage[key] = data
            adds += 1
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard let key = key(from: query), storage[key] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            storage[key] = data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if let service = query[kSecAttrService as String] as? String,
                query[kSecAttrAccount as String] == nil
            {
                let dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
                let matches = storage.keys.filter {
                    $0.service == service && $0.dataProtection == dataProtection
                }
                guard !matches.isEmpty else { return errSecItemNotFound }
                for key in matches { storage.removeValue(forKey: key) }
                deletes += 1
                return errSecSuccess
            }
            guard let key = key(from: query), storage.removeValue(forKey: key) != nil else {
                return errSecItemNotFound
            }
            deletes += 1
            return errSecSuccess
        }
    }

    func seed(_ data: Data, item: AppleKeychainItem, dataProtection: Bool) {
        lock.withLock {
            storage[Key(service: item.service, account: item.account, dataProtection: dataProtection)] = data
        }
    }

    func storedData(for item: AppleKeychainItem, dataProtection: Bool) -> Data? {
        lock.withLock {
            storage[Key(service: item.service, account: item.account, dataProtection: dataProtection)]
        }
    }

    private func key(from query: [String: Any]) -> Key? {
        guard let service = query[kSecAttrService as String] as? String,
            let account = query[kSecAttrAccount as String] as? String
        else { return nil }
        return Key(
            service: service,
            account: account,
            dataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
        )
    }
}
