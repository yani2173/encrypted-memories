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

    @Test func theClassOfAnItemIsReadFromItsAttributesOnly() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let item = uniqueItem("class")
        #expect(try store.accessibility(for: item) == nil, "no item, no class")

        security.seed(
            Data("saved".utf8), item: item, dataProtection: true,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(try store.accessibility(for: item) == .whenUnlockedThisDeviceOnly)
        let query = try #require(security.lastReadQuery)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnData as String] == nil, "the class read never asks for the data")
    }

    @Test func aSaveWithAnotherClassUpdatesTheItemInPlace() throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let old = uniqueItem("move")
        security.seed(
            Data("saved".utf8), item: old, dataProtection: true,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        let new = AppleKeychainItem(
            service: old.service, account: old.account, accessibility: .afterFirstUnlockThisDeviceOnly)

        try store.setData(Data("saved".utf8), for: new)

        #expect(try store.accessibility(for: new) == .afterFirstUnlockThisDeviceOnly)
        #expect(security.addCount == 0)
        #expect(security.deleteCount == 0)
    }

    @Test(arguments: [AppleKeychainAccessibility.whenUnlockedThisDeviceOnly, .afterFirstUnlockThisDeviceOnly])
    func signOutRemovesTheSessionWhateverClassItWasSavedWith(_ saved: AppleKeychainAccessibility) throws {
        let security = MemorySecurityItemClient()
        let store = SystemAppleKeychainStore(security: security)
        let service = "at.oncloud.encryptedmemories.security-tests.signout.\(UUID().uuidString)"
        let savedItem = AppleKeychainItem(service: service, account: "default", accessibility: saved)
        try store.setData(Data("session".utf8), for: savedItem)
        let other: AppleKeychainAccessibility =
            saved == .whenUnlockedThisDeviceOnly ? .afterFirstUnlockThisDeviceOnly : .whenUnlockedThisDeviceOnly

        // The store of the new app version removes an item of either class: the queries carry no class.
        try store.removeData(for: AppleKeychainItem(service: service, account: "default", accessibility: other))
        #expect(security.storedData(for: savedItem, dataProtection: true) == nil)
        #expect(security.deleteQueries.allSatisfy { $0[kSecAttrAccessible as String] == nil })

        try store.setData(Data("session".utf8), for: savedItem)
        try store.removeAllData(service: service)
        #expect(security.storedData(for: savedItem, dataProtection: true) == nil, "the sign-out purge removes it too")
        #expect(security.deleteQueries.allSatisfy { $0[kSecAttrAccessible as String] == nil })
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
    private var classes: [Key: String] = [:]
    private var adds = 0
    private var deletes = 0
    private var readQuery: [String: Any]?
    private var deletions: [[String: Any]] = []

    var lastReadQuery: [String: Any]? { lock.withLock { readQuery } }
    var deleteQueries: [[String: Any]] { lock.withLock { deletions } }

    var addCount: Int { lock.withLock { adds } }
    var deleteCount: Int { lock.withLock { deletes } }

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        lock.withLock {
            readQuery = query
            guard let key = key(from: query), let data = storage[key] else {
                return SecurityItemCopyResult(status: errSecItemNotFound, data: nil)
            }
            if query[kSecReturnAttributes as String] as? Bool == true {
                return SecurityItemCopyResult(status: errSecSuccess, data: nil, accessible: classes[key])
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
            classes[key] = (attributes[kSecAttrAccessible as String] as! CFString) as String
            adds += 1
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard let key = key(from: query), storage[key] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            storage[key] = data
            if let accessible = attributes[kSecAttrAccessible as String] {
                classes[key] = (accessible as! CFString) as String
            }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deletions.append(query)
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

    func seed(_ data: Data, item: AppleKeychainItem, dataProtection: Bool, accessible: CFString? = nil) {
        lock.withLock {
            let key = Key(service: item.service, account: item.account, dataProtection: dataProtection)
            storage[key] = data
            if let accessible { classes[key] = accessible as String }
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
