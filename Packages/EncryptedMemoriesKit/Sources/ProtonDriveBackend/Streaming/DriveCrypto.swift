import Foundation
import PhotosCore
import ProtonCoreCrypto
import ProtonCoreCryptoGoInterface
import ProtonCoreDataModel

/// A private key plus the passphrase that unlocks it - enough to build a decryption key ring on
/// demand. (We rebuild rings per operation rather than holding live gopenpgp objects, so there's
/// no shared mutable crypto state to guard.)
struct UnlockableKey: Sendable {
    let armored: String
    let passphrase: String
}

enum DriveCryptoError: Error { case keyRing, badMessage, base64 }

/// Each case is deterministic key or message data that a second attempt reads the same way.
extension DriveCryptoError: VideoPlaybackClassifiable {
    var videoPlaybackError: VideoPlaybackError? { .decryptionFailed }
}

/// Proton Drive key derivation and per-block decryption for file streaming. The chain is address key,
/// share key, node key, content session key, then block decryption. Pure crypto;
/// network/JSON lives in `PhotoVideoStreamSource`. The gopenpgp calls match ProtonCore's own
/// `Crypto+Extension.swift` / `KeyRingBuilder.swift` usage.
final class DriveCrypto: @unchecked Sendable {
    /// Address private keys, pre-resolved to (armored, passphrase) so a ring can be built any time.
    private let addressKeys: [UnlockableKey]
    /// The same address keys with their address identity kept, for WRITE operations that must name
    /// a signature email (album create / add-to-album). One entry per active key, address order
    /// preserved (Proton lists the primary address first).
    let signers: [DriveCryptoSigner]
    /// Serializes block decryption - AVFoundation can issue concurrent range requests, and a single
    /// gopenpgp session key isn't guaranteed safe to decrypt with from multiple threads at once.
    private let blockLock = NSLock()

    init(account: AccountData, keyPassword: String) {
        var keys: [UnlockableKey] = []
        var signers: [DriveCryptoSigner] = []
        for address in account.addresses {
            for key in address.keys where key.active == 1 {
                if let pass = try? key.passphrase(userKeys: account.userKeys, mailboxPassphrase: keyPassword) {
                    let unlockable = UnlockableKey(armored: key.privateKey, passphrase: pass.value)
                    keys.append(unlockable)
                    signers.append(
                        DriveCryptoSigner(
                            addressID: address.addressID,
                            addressKeyID: key.keyID,
                            email: address.email,
                            key: unlockable
                        ))
                }
            }
        }
        self.addressKeys = keys
        self.signers = signers
    }

    /// Test seam: build directly from resolved keys (production always goes through `AccountData`).
    init(addressKeys: [UnlockableKey], signers: [DriveCryptoSigner]) {
        self.addressKeys = addressKeys
        self.signers = signers
    }

    // MARK: - Ring building

    func unlockedKey(_ k: UnlockableKey) throws -> CryptoKey {
        var error: NSError?
        guard let key = CryptoGo.CryptoNewKeyFromArmored(k.armored, &error), error == nil else {
            throw DriveCryptoError.keyRing
        }
        return try key.unlock(k.passphrase.data(using: .utf8))
    }

    func ring(_ keys: [UnlockableKey]) throws -> CryptoKeyRing {
        var error: NSError?
        guard let ring = CryptoGo.CryptoNewKeyRing(nil, &error), error == nil else {
            throw DriveCryptoError.keyRing
        }
        for k in keys { try ring.add(try unlockedKey(k)) }
        return ring
    }

    /// Decrypts an armored PGP message (a share/node passphrase, or XAttr) with the given keys.
    /// `verifyKey: nil` - the reference clients treat signature verification as best-effort and
    /// non-fatal, and for streaming we don't have the material to verify, so we skip it.
    func decryptArmored(_ armored: String, with keys: [UnlockableKey]) throws -> CryptoPlainMessage {
        let ring = try ring(keys)
        defer { ring.clearPrivateParams() }
        var error: NSError?
        guard let msg = CryptoGo.CryptoNewPGPMessageFromArmored(armored, &error), error == nil else {
            throw DriveCryptoError.badMessage
        }
        return try ring.decrypt(msg, verifyKey: nil, verifyTime: 0)
    }

    // MARK: - Chain steps

    /// Decrypts a share passphrase with the address keys and returns its share key.
    func unlockShare(key: String, passphrase: String) throws -> UnlockableKey {
        let clear = try decryptArmored(passphrase, with: addressKeys).getString()
        return UnlockableKey(armored: key, passphrase: clear)
    }

    /// Decrypts a node passphrase with its parent key and returns its node key.
    func unlockNode(key: String, passphrase: String, parent: UnlockableKey) throws -> UnlockableKey {
        let clear = try decryptArmored(passphrase, with: [parent]).getString()
        return UnlockableKey(armored: key, passphrase: clear)
    }

    /// Decrypts a base64 content-key packet with the node key and returns the file session key.
    func contentSessionKey(contentKeyPacketBase64 packet: String, node: UnlockableKey) throws -> CryptoSessionKey {
        guard let data = Data(base64Encoded: packet) else { throw DriveCryptoError.base64 }
        let ring = try ring([node])
        defer { ring.clearPrivateParams() }
        return try ring.decryptSessionKey(data)
    }

    /// Decrypts the armored XAttr blob with the node key and returns cleartext JSON bytes.
    func decryptXAttr(_ armored: String, node: UnlockableKey) throws -> Data {
        try decryptArmored(armored, with: [node]).data ?? Data()
    }

    /// Decrypts a folder's armored `NodeHashKey` with the folder's own node key to obtain the plaintext
    /// hash-key string. For the photos root this string (Proton generates the base64 of 32 random
    /// bytes) is the HMAC key for photo name/content hashes. Signature verification is skipped,
    /// matching the reference clients' use-even-if-unverified stance (and this class's other
    /// decrypt paths).
    func decryptNodeHashKey(_ armored: String, node: UnlockableKey) throws -> String {
        try decryptArmored(armored, with: [node]).getString()
    }

    /// Decrypts a link's armored `Name` with its parent node key to obtain the cleartext filename. (Names are
    /// encrypted to the parent node key, unlike XAttr which uses the file's own node key.)
    func decryptName(_ armored: String, parent: UnlockableKey) throws -> String {
        try decryptArmored(armored, with: [parent]).getString()
    }

    /// Decrypts one block (an independent OpenPGP data packet) with the content session key.
    /// No signature/manifest verification - streaming never downloads all blocks, matching web.
    func decryptBlock(_ dataPacket: Data, sessionKey: CryptoSessionKey) throws -> Data {
        blockLock.lock()
        defer { blockLock.unlock() }
        return try sessionKey.decrypt(dataPacket).data ?? Data()
    }
}
