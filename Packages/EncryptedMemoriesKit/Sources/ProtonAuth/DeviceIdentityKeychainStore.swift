import AppleSecurityCore
import Foundation
import PhotosCore

/// Device-local installation identity used to distinguish concurrent Proton upload clients. It is
/// not an account credential and never synchronizes through iCloud Keychain. A full app logout removes
/// it together with interrupted upload state; the next authenticated session creates a fresh identity.
public struct DeviceIdentityKeychainStore: Sendable {
    private static let productionService = "at.oncloud.encryptedmemories.device-identity"
    #if ENCRYPTED_MEMORIES_UPGRADE_TEST
        public static let defaultService = productionService + ".upgrade-test"
    #else
        public static let defaultService = productionService
    #endif
    private let item: AppleKeychainItem
    private let keychain: any AppleKeychainStoring

    public init(
        service: String = Self.defaultService,
        account: String = "installation"
    ) {
        self.init(service: service, account: account, keychain: SystemAppleKeychainStore())
    }

    public init(
        service: String,
        account: String,
        keychain: any AppleKeychainStoring
    ) {
        self.item = AppleKeychainItem(
            service: service,
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        self.keychain = keychain
    }

    public func loadOrCreate() -> String {
        if let existing = load() { return existing }

        let generated = UUID().uuidString
        let durable: Data?
        do {
            durable = try keychain.dataOrInsert(Data(generated.utf8), for: item)
        } catch {
            Self.reportKeychainError(error, operation: "dataOrInsert")
            durable = nil
        }
        return durable.flatMap { String(data: $0, encoding: .utf8) } ?? generated
    }

    func clear() {
        try? keychain.removeData(for: item)
    }

    private func load() -> String? {
        do {
            guard let data = try keychain.data(for: item),
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            else { return nil }
            return value
        } catch {
            Self.reportKeychainError(error, operation: "load")
            return nil
        }
    }

    private static func reportKeychainError(_ error: Error, operation: String) {
        let status = (error as? AppleSecurityError).map { String($0.status) } ?? "other"
        PhotoDiagnostics.shared.emit(
            "DeviceIdentityKeychain", ["operation": operation, "status": status], throttleSeconds: 60)
    }
}
