#if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)
    import AppleSecurityCore
    import Foundation
    import PhotosCore

    /// Only the synthetic account uses this store. The macOS Data Protection Keychain needs an Apple team.
    struct UpgradeTestSessionFile: AppleKeychainStoring {
        private var url: URL {
            LibraryDatabaseLocation.accountDirectory(uid: UpgradeTestProbe.accountUID)
                .appendingPathComponent("upgrade-fixture-session.json")
        }

        private func check(_ item: AppleKeychainItem) throws {
            guard UpgradeTestProbe.isRequested, item.service == SessionKeychainStore.defaultService,
                item.account == "default"
            else { throw SessionKeychainError.invalidPayload }
        }

        func data(for item: AppleKeychainItem) throws -> Data? {
            try check(item)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        func setData(_ data: Data, for item: AppleKeychainItem) throws {
            try check(item)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
            if let existing = try self.data(for: item) { return existing }
            try setData(data, for: item)
            return data
        }
        func removeData(for item: AppleKeychainItem) throws {
            try check(item)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        func removeAllData(service: String) throws {
            try removeData(
                for: AppleKeychainItem(
                    service: service, account: "default", accessibility: .whenUnlockedThisDeviceOnly))
        }
    }
#endif
