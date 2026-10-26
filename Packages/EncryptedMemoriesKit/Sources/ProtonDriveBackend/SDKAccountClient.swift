import Foundation
import ProtonCoreCrypto
import ProtonCoreCryptoGoInterface
import ProtonCoreDataModel
import ProtonDriveSDK

/// Supplies the Proton Drive SDK with the user's addresses and their *unlocked* private keys,
/// so the C# core can decrypt node/thumbnail metadata. All key material is unlocked once at
/// sign-in (see `SDKAccountClientBuilder`) and read synchronously here, as the SDK requires.
///
/// SDK 0.32.1 no longer accepts `ProtonCoreDataModel.Address`. The app maps its ProtonCore account
/// data into the SDK-owned `AccountClientAddress` through `SDKAddressDescriptor`, which keeps the
/// key-capability derivation testable without `@testable` access to the SDK module.
struct SDKAccountClient: AccountClientProtocol, @unchecked Sendable {
    let addresses: [Address]
    let unlockedByKeyID: [String: Data]

    func getAddress(addressId: String) -> AccountClientAddress? {
        coreAddress(addressId: addressId).map { SDKAddressDescriptor(address: $0).sdkAddress }
    }

    func getDefaultAddress() -> AccountClientAddress? {
        defaultCoreAddress().map { SDKAddressDescriptor(address: $0).sdkAddress }
    }

    func getAddressPrimaryPrivateKey(addressId: String) -> Data? {
        guard let address = coreAddress(addressId: addressId),
            let primary = SDKAddressDescriptor.primaryKey(of: address.keys)
        else { return nil }
        return unlockedByKeyID[primary.keyID]
    }

    func getAddressPrivateKeys(addressId: String) -> [Data]? {
        guard let address = coreAddress(addressId: addressId) else { return nil }
        let keys = address.keys.filter { $0.active == 1 }.compactMap { unlockedByKeyID[$0.keyID] }
        return keys.isEmpty ? nil : keys
    }

    func getAddressPublicKeysRequest(emailAddress: String) -> [Data] {
        // Shared-content signature verification can supply external public keys here when that surface is added.
        // Own-library timeline, thumbnails, uploads, and album sync only need the signed-in account keys above.
        []
    }

    func coreAddress(addressId: String) -> Address? {
        addresses.first { $0.addressID == addressId }
    }

    func defaultCoreAddress() -> Address? {
        addresses.min { $0.order < $1.order } ?? addresses.first
    }
}

/// App-owned, fully readable projection of one ProtonCore `Address` into the SDK 0.32.1 account
/// contract. Before 0.27.0 the SDK derived these booleans itself from `Key.keyFlags`; the mapping
/// here reproduces that derivation exactly (`KeyFlags.encryptNewData` / `.verifySignatures`).
struct SDKAddressDescriptor: Equatable, Sendable {
    struct KeyDescriptor: Equatable, Sendable {
        let addressID: String
        let keyID: String
        let isActive: Bool
        let isAllowedForEncryption: Bool
        let isAllowedForVerification: Bool
    }

    enum Status: Equatable, Sendable {
        case enabled
        case disabled
    }

    let addressID: String
    let order: Int32
    let emailAddress: String
    let status: Status
    let primaryKeyIndex: Int32
    let keys: [KeyDescriptor]

    init(address: Address) {
        addressID = address.addressID
        order = Int32(clamping: address.order)
        emailAddress = address.email
        status = address.status == .disabled ? .disabled : .enabled
        primaryKeyIndex = Self.primaryKeyIndex(of: address.keys)
        keys = address.keys.map { key in
            KeyDescriptor(
                addressID: address.addressID,
                keyID: key.keyID,
                isActive: key.active == 1,
                isAllowedForEncryption: Self.keyFlags(key).contains(.encryptNewData),
                isAllowedForVerification: Self.keyFlags(key).contains(.verifySignatures)
            )
        }
    }

    var sdkAddress: AccountClientAddress {
        AccountClientAddress(
            addressID: addressID,
            order: order,
            emailAddress: emailAddress,
            status: status == .disabled ? .disabled : .enabled,
            primaryKeyIndex: primaryKeyIndex,
            keys: keys.map { key in
                AccountClientAddress.Key(
                    addressID: key.addressID,
                    addressKeyID: key.keyID,
                    isActive: key.isActive,
                    isAllowedForEncryption: key.isAllowedForEncryption,
                    isAllowedForVerification: key.isAllowedForVerification
                )
            }
        )
    }

    /// The key Proton flags as primary, or the first key when no flag is set. Matches the SDK's
    /// former `keys.firstIndex(where: { $0.primary == 1 }) ?? 0`.
    static func primaryKeyIndex(of keys: [Key]) -> Int32 {
        Int32(clamping: keys.firstIndex(where: { $0.primary == 1 }) ?? 0)
    }

    static func primaryKey(of keys: [Key]) -> Key? {
        keys.first(where: { $0.primary == 1 }) ?? keys.first
    }

    /// Proton key flags occupy the low byte; the SDK previously truncated the same way.
    private static func keyFlags(_ key: Key) -> KeyFlags {
        KeyFlags(rawValue: UInt8(truncatingIfNeeded: key.keyFlags))
    }
}

enum SDKAccountClientBuilder {
    /// Unlocks every active address key using the mailbox key password from the fork payload.
    static func build(account: AccountData, keyPassword: String) throws -> SDKAccountClient {
        var unlocked: [String: Data] = [:]

        for address in account.addresses {
            for key in address.keys where key.active == 1 {
                guard let data = try? unlock(key, userKeys: account.userKeys, keyPassword: keyPassword) else {
                    continue
                }
                unlocked[key.keyID] = data
            }
        }
        return SDKAccountClient(addresses: account.addresses, unlockedByKeyID: unlocked)
    }

    private static func unlock(_ key: Key, userKeys: [Key], keyPassword: String) throws -> Data {
        let passphrase = try key.passphrase(userKeys: userKeys, mailboxPassphrase: keyPassword)
        var error: NSError?
        guard let cryptoKey = CryptoGo.CryptoNewKeyFromArmored(key.privateKey, &error), error == nil else {
            throw error ?? CocoaError(.coderInvalidValue)
        }
        let unlockedKey = try cryptoKey.unlock(passphrase.value.data(using: .utf8))
        return try unlockedKey.serialize()
    }
}
