import AppleSecurityCore
import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing
import UploadCore

@testable import ProtonDriveBackend
@testable import ProtonDriveSDK

@Suite("Related-file bridge transfers", .serialized)
struct DriveSDKRelatedFileTransferTests {
    @Test func sdkClientConstructsOfflineWithoutAccountKeysOrHTTP() async throws {
        RelatedFileDenyHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let governor = ProtonRequestGovernor()
        let session = makeSession(directory: directory, governor: governor)
        let client = try await makeSDKClient(session: session, governor: governor)

        #expect(RelatedFileDenyHTTP.requestCount == 0)
        await client.shutdown()
        #expect(RelatedFileDenyHTTP.requestCount == 0)
    }

    @Test func realBridgeDispatchesUploadThroughTheExistentialOffline() async throws {
        RelatedFileDenyHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("related.jpg")
        let bytes = Data("related bytes".utf8)
        try bytes.write(to: file)
        let probe = RelatedFileBridgeProbe()
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, request, _ in await probe.upload(request) })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let request = try request(file: file, allowsExpensiveNetwork: true)
            do {
                let uploaded = try await remote.uploadRelatedFile(request)
                #expect(uploaded == PhotoUID(volumeID: "vol", nodeID: "copied"))
            } catch {
                await bridge.shutdown()
                throw error
            }
            await bridge.shutdown()
            #expect(await probe.uploadCount == 1)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(await probe.reservation?.isActive == false)
            #expect(RelatedFileDenyHTTP.requestCount == 0)
        }
    }

    @Test func realBridgeDispatchesDownloadThroughTheExistentialOffline() async throws {
        RelatedFileDenyHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        let expected = SeriesMemberSource(
            filename: "related.jpg", mediaType: "image/jpeg", captureTime: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2), additionalMetadata: [])
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                source: { _, uid in
                    #expect(uid == PhotoUID(volumeID: "vol", nodeID: "related"))
                    await probe.readSource()
                    return ExactDuplicateRelatedFileSource(metadata: expected, claimedSize: 3)
                },
                stream: { _, uid, policy, consume in
                    #expect(uid == PhotoUID(volumeID: "vol", nodeID: "related"))
                    #expect(!policy)
                    await probe.stream()
                    try await consume(Data("abc".utf8))
                })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let destination = directory.appendingPathComponent("related.partial")
            do {
                let metadata = try await remote.downloadRelatedFile(
                    PhotoUID(volumeID: "vol", nodeID: "related"), to: destination, allowsExpensiveNetwork: false)
                #expect(metadata == expected)
                #expect(try Data(contentsOf: destination) == Data("abc".utf8))
            } catch {
                await bridge.shutdown()
                throw error
            }
            await bridge.shutdown()
            #expect(await probe.sourceCount == 1)
            #expect(await probe.streamCount == 1)
            #expect(RelatedFileDenyHTTP.requestCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func bridgeReservesTheExplicitPolicyAndCleansAfterUploadFailure(policy: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, request, _ in
                    _ = await probe.upload(request)
                    throw URLError(.networkConnectionLost)
                })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("related.jpg")
            try Data("abc".utf8).write(to: file)
            let request = try request(file: file, allowsExpensiveNetwork: policy)
            await #expect(throws: ExactDuplicateRelatedFileTransferError.copyFailed(.transfer)) {
                try await remote.uploadRelatedFile(request)
            }
            await bridge.shutdown()
            #expect(await probe.uploadCount == 1)
            #expect(await probe.reservation?.allowsExpensiveNetwork == policy)
            #expect(await probe.reservation?.isActive == false)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test(arguments: [true, false])
    func bridgeChecksProtonStorageBeforeTheTransport(full: Bool) async throws {
        RelatedFileDenyHTTP.reset()
        defer { RelatedFileDenyHTTP.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        let bridge = try await makeBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, request, _ in await probe.upload(request) }))
        let file = directory.appendingPathComponent("related.jpg")
        try Data("abc".utf8).write(to: file)
        let request = try request(file: file, allowsExpensiveNetwork: false)
        let remote: any ExactDuplicateRemote = bridge
        // Nothing throws between this shared quota and its removal.
        let account = "related-quota-fixture"
        await MainActor.run {
            AccountInfo.shared.beginSession(accountUID: account)
            AccountInfo.shared.updateDriveStorage(usedBytes: full ? 1_000 : 0, maxBytes: 1_000, accountUID: account)
        }
        let result: Result<PhotoUID, any Error>
        do { result = .success(try await remote.uploadRelatedFile(request)) } catch { result = .failure(error) }
        await bridge.shutdown()
        await MainActor.run { AccountInfo.shared.clear() }

        if full {
            #expect(throws: ExactDuplicateRelatedFileTransferError.copyFailed(.accountStorage)) { try result.get() }
            // The full answer is refreshed once, as for a backup upload; the offline fixture refuses it.
            #expect(RelatedFileDenyHTTP.requestCount >= 1)
        } else {
            #expect(try result.get() == PhotoUID(volumeID: "vol", nodeID: "copied"))
            #expect(RelatedFileDenyHTTP.requestCount == 0)
        }
        #expect(await probe.uploadCount == (full ? 0 : 1))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aClosedBridgeRemovesUploadStagingWithoutInvokingTheTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, request, _ in await probe.upload(request) })
        ) { bridge in
            await bridge.shutdown()
            let file = directory.appendingPathComponent("related.jpg")
            try Data("abc".utf8).write(to: file)
            let request = try request(file: file, allowsExpensiveNetwork: false)
            let remote: any ExactDuplicateRemote = bridge
            await #expect(throws: CancellationError.self) { try await remote.uploadRelatedFile(request) }
            #expect(await probe.uploadCount == 0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func aClosedBridgeDownloadCreatesNothingAndInvokesNoOperations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                source: { _, _ in
                    Issue.record("No source read after shutdown")
                    throw CancellationError()
                },
                stream: { _, _, _, _ in Issue.record("No stream after shutdown") })
        ) { bridge in
            await bridge.shutdown()
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("related.partial")
            await #expect(throws: CancellationError.self) {
                try await remote.downloadRelatedFile(
                    PhotoUID(volumeID: "vol", nodeID: "related"), to: file, allowsExpensiveNetwork: false)
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func blockRequestsKeepTheLegacyDefaultAndForwardExplicitWiFiOnlyPolicy() async throws {
        RelatedFileBlockHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = DriveSession(
            session: ProtonSession(uid: "fixture", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(
                service: "related-file-fixture", account: "fixture", keychain: RelatedFileDenyKeychain()),
            accountCacheDirectory: directory, urlProtocolClasses: [RelatedFileBlockHTTP.self])
        _ = try await session.fetchBlock(url: "https://fixture.invalid/block", token: nil)
        _ = try await session.fetchBlock(
            url: "https://fixture.invalid/block", token: nil, allowsExpensiveNetwork: false)
        let source = PhotoVideoStreamSource(
            session: session, crypto: DriveCrypto(addressKeys: [], signers: []), shareID: "fixture")
        let block = VideoBlock(
            index: 1, url: "https://fixture.invalid/block", token: nil, clearOffset: 0, clearSize: 3)
        _ = try await source.encryptedBlockData(block)
        _ = try await source.encryptedBlockData(block, allowsExpensiveNetwork: false)
        _ = try await source.encryptedBlockData(block, priority: .background, allowsExpensiveNetwork: false)
        #expect(RelatedFileBlockHTTP.policies == [true, false, true, false, false])
    }

    @Test func bridgeWaitsForWiFiWithoutReadingDownloadingOrUploading() async throws {
        RelatedFileDenyHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory, network: .init(isExpensive: true)),
                source: { _, _ in
                    await probe.readSource()
                    throw URLError(.notConnectedToInternet)
                },
                stream: { _, _, _, _ in await probe.stream() },
                uploadTransport: { _, request, _ in await probe.upload(request) })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("related.jpg")
            await #expect(throws: ExactDuplicateRelatedFileTransferError.waitingForWiFi) {
                try await remote.downloadRelatedFile(
                    PhotoUID(volumeID: "vol", nodeID: "related"), to: file, allowsExpensiveNetwork: false)
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
            try Data("abc".utf8).write(to: file)
            let request = try request(file: file, allowsExpensiveNetwork: false)
            await #expect(throws: ExactDuplicateRelatedFileTransferError.waitingForWiFi) {
                try await remote.uploadRelatedFile(request)
            }
            await bridge.shutdown()
            #expect(await probe.sourceCount == 0)
            #expect(await probe.streamCount == 0)
            #expect(await probe.uploadCount == 0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(RelatedFileDenyHTTP.requestCount == 0)
        }
    }

    @Test func bridgeMapsAnUnsupportedSourceToCopyFailedWithoutStreaming() async throws {
        RelatedFileDenyHTTP.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = RelatedFileBridgeProbe()
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                source: { _, _ in
                    await probe.readSource()
                    throw CocoaError(.fileReadUnknown)
                },
                stream: { _, _, _, _ in await probe.stream() })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("related.jpg")
            await #expect(throws: ExactDuplicateRelatedFileTransferError.copyFailed(.transfer)) {
                try await remote.downloadRelatedFile(
                    PhotoUID(volumeID: "vol", nodeID: "related"), to: file, allowsExpensiveNetwork: false)
            }
            await bridge.shutdown()
            #expect(await probe.sourceCount == 1)
            #expect(await probe.streamCount == 0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(RelatedFileDenyHTTP.requestCount == 0)
        }
    }

    @Test(arguments: [URLError.Code.dataNotAllowed, .cancelled])
    func bridgeKeepsCompatibilityWithLegacyTypedUploadErrors(code: URLError.Code) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, _, _ in
                    throw DriveSDKBridge.uploadError(from: URLError(code), filename: "related.jpg")
                })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("related.jpg")
            try Data("abc".utf8).write(to: file)
            let request = try request(file: file, allowsExpensiveNetwork: false)
            do {
                _ = try await remote.uploadRelatedFile(request)
                Issue.record("A refused or cancelled transfer must not return a UID")
            } catch {
                if code == .cancelled {
                    #expect(error is CancellationError)
                } else {
                    #expect(error as? ExactDuplicateRelatedFileTransferError == .waitingForWiFi)
                }
            }
            await bridge.shutdown()
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test(arguments: [false, true])
    func relatedFileLoggingOmitsPrivateDetailsOnSuccessAndSDKFailure(fails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private-original.jpg")
        let sink = RelatedFileLogSink()
        let failure = NSError(
            domain: "fixture-sdk", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "private-original.jpg \(file.path) raw SDK failure"])
        try await withBridge(
            directory: directory,
            operations: .init(
                transfer: transfer(directory: directory),
                uploadTransport: { _, request, logging in
                    if fails {
                        logging.cancellationCleanupFailed(filename: request.name, error: failure)
                        logging.failed(filename: request.name, error: failure)
                        throw failure
                    }
                    logging.completed(nodeID: "copied", filename: request.name)
                    return PhotoUID(volumeID: "vol", nodeID: "copied")
                },
                log: { sink.append($0) })
        ) { bridge in
            let remote: any ExactDuplicateRemote = bridge
            try Data("abc".utf8).write(to: file)
            let upload = try request(file: file, allowsExpensiveNetwork: false, name: "private-original.jpg")
            if fails {
                await #expect(throws: ExactDuplicateRelatedFileTransferError.copyFailed(.transfer)) {
                    try await remote.uploadRelatedFile(upload)
                }
            } else {
                #expect(try await remote.uploadRelatedFile(upload) == PhotoUID(volumeID: "vol", nodeID: "copied"))
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(sink.lines == [])
            #expect(sink.lines.allSatisfy { !$0.contains(upload.name) && !$0.contains(file.path) })
            #expect(sink.lines.allSatisfy { !$0.contains("raw SDK failure") })
        }
    }

    @Test func ordinaryUploadLoggingKeepsItsExistingMessages() {
        let sink = RelatedFileLogSink()
        let logging = DriveSDKBridge.UploadLogging(log: { sink.append($0) })
        let failure: any Error = URLError(.cancelled)
        logging.completed(nodeID: "abcdefghijk", filename: "fixture.jpg")
        logging.cancellationCleanupFailed(filename: "fixture.jpg", error: failure)
        logging.failed(filename: "fixture.jpg", error: failure)
        #expect(
            sink.lines == [
                "[Upload] completed node=abcdefgh… file=fixture.jpg",
                "[Upload] cancellation cleanup failed file=fixture.jpg err=\(failure)",
                "[Upload] FAILED file=fixture.jpg err=\(failure)",
            ])
    }

    @Test(arguments: [false, true])
    func rawRelatedErrorsReachTheBridgeForDownloadAndUpload(wrapped: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for code in [URLError.Code.dataNotAllowed, .cancelled, .notConnectedToInternet] {
            for reason in [nil, .expensive, .constrained] as [URLError.NetworkUnavailableReason?] {
                var info: [String: Any] = [:]
                if let reason { info[NSURLErrorNetworkUnavailableReasonKey] = NSNumber(value: reason.rawValue) }
                let raw = URLError(code, userInfo: info)
                let error: any Error =
                    wrapped
                    ? NSError(domain: "fixture-wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: raw]) : raw
                try await withBridge(
                    directory: directory,
                    operations: .init(
                        transfer: transfer(directory: directory),
                        source: { _, _ in throw error },
                        uploadTransport: { _, _, _ in throw error })
                ) { bridge in
                    let remote: any ExactDuplicateRemote = bridge
                    let file = directory.appendingPathComponent("related.partial")
                    do {
                        _ = try await remote.downloadRelatedFile(
                            PhotoUID(volumeID: "vol", nodeID: "related"), to: file, allowsExpensiveNetwork: false)
                        Issue.record("A failed download must not return metadata")
                    } catch { assertRawError(error, code: code, reason: reason) }
                    #expect(!FileManager.default.fileExists(atPath: file.path))
                    try Data("abc".utf8).write(to: file)
                    let request = try request(file: file, allowsExpensiveNetwork: false)
                    do {
                        _ = try await remote.uploadRelatedFile(request)
                        Issue.record("A failed upload must not return a UID")
                    } catch { assertRawError(error, code: code, reason: reason) }
                    #expect(!FileManager.default.fileExists(atPath: file.path))
                }
            }
        }
    }

    private func assertRawError(
        _ error: any Error, code: URLError.Code, reason: URLError.NetworkUnavailableReason?
    ) {
        if code == .cancelled {
            #expect(error is CancellationError)
        } else {
            #expect(
                error as? ExactDuplicateRelatedFileTransferError
                    == (code == .dataNotAllowed || reason == .expensive ? .waitingForWiFi : .copyFailed(.transfer)))
        }
    }

    @Test func theNativeUploadImplErrorPathOmitsPrivateDetailsOffline() async throws {
        RelatedFileDenyHTTP.reset()
        defer { RelatedFileDenyHTTP.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RelatedFileLogSink()
        let bridge = try await makeBridge(
            directory: directory,
            operations: .init(transfer: transfer(directory: directory), log: { sink.append($0) }))
        do {
            let remote: any ExactDuplicateRemote = bridge
            let file = directory.appendingPathComponent("private-original.jpg")
            try Data("abc".utf8).write(to: file)
            let upload = try request(file: file, allowsExpensiveNetwork: false, name: file.lastPathComponent)
            await #expect(throws: ExactDuplicateRelatedFileTransferError.copyFailed(.transfer)) {
                try await remote.uploadRelatedFile(upload)
            }
            #expect(sink.lines.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        // The real SDK reaches one HTTP request, which the deny-all URLProtocol rejects without networking.
        #expect(RelatedFileDenyHTTP.requestCount == 1)
        #expect(sink.lines.isEmpty)
    }

    @Test func streamOriginalBytesKeepsTheViewerDefaultOnTheActualBlockRequest() async throws {
        _ = relatedStreamCryptoReady
        let boot = DriveCrypto(addressKeys: [], signers: [])
        func key() throws -> UnlockableKey {
            let passphrase = try boot.randomBase64Token()
            return UnlockableKey(
                armored: try boot.generateLockedNodeKey(passphrase: passphrase), passphrase: passphrase)
        }
        let address = try key()
        let share = try key()
        let node = try key()
        let crypto = DriveCrypto(addressKeys: [address], signers: [])
        var keyError: NSError?
        let sessionKey = try #require(CryptoGo.CryptoGenerateSessionKey(&keyError))
        #expect(keyError == nil)
        defer { _ = sessionKey.clear() }
        let ring = try crypto.ring([node])
        defer { ring.clearPrivateParams() }
        let packet = try ring.encryptSessionKey(sessionKey).base64EncodedString()
        let encrypted = try sessionKey.encrypt(CryptoGo.CryptoNewPlainMessageFromString("abc"))
        let routes: [String: Data] = [
            "/drive/shares/fixture": try JSONSerialization.data(withJSONObject: [
                "Code": 1000, "Key": share.armored,
                "Passphrase": try crypto.encrypt(text: share.passphrase, to: address),
            ]),
            "/drive/shares/fixture/links/related": try JSONSerialization.data(withJSONObject: [
                "Code": 1000,
                "Link": [
                    "LinkID": "related", "NodeKey": node.armored,
                    "NodePassphrase": try crypto.encrypt(text: node.passphrase, to: share),
                    "XAttr": try crypto.encrypt(text: #"{"Common":{"Size":3,"BlockSizes":[3]}}"#, to: node),
                    "FileProperties": ["ContentKeyPacket": packet, "ActiveRevision": ["ID": "revision"]],
                ],
            ]),
            "/drive/shares/fixture/files/related/revisions/revision": try JSONSerialization.data(withJSONObject: [
                "Code": 1000, "Revision": ["Blocks": [["Index": 1, "URL": "https://fixture.invalid/block"]]],
            ]),
            "/block": encrypted,
        ]
        RelatedFileBlockHTTP.reset(routes: routes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DriveSession(
            session: ProtonSession(uid: "fixture", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(
                service: "related-file-fixture", account: "fixture", keychain: RelatedFileDenyKeychain()),
            accountCacheDirectory: directory, urlProtocolClasses: [RelatedFileBlockHTTP.self])
        let stream = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "fixture")
        let bytes = RelatedFileStreamBytes()
        try await stream.streamOriginalBytes(
            uid: PhotoUID(volumeID: "vol", nodeID: "related"),
            onChunk: { await bytes.append($0) }, onProgress: { _ in })
        #expect(await bytes.data == Data("abc".utf8))
        #expect(RelatedFileBlockHTTP.policies == [true, true, true, true])
        RelatedFileBlockHTTP.reset(routes: routes)
        try await stream.streamOriginalBytes(
            uid: PhotoUID(volumeID: "vol", nodeID: "related"), allowsExpensiveNetwork: false,
            onChunk: { _ in }, onProgress: { _ in })
        #expect(RelatedFileBlockHTTP.policies == [true, true, false])
    }

    @Test func sdkSerializationDiscardsTheReasonAndBridgeDecodesOnlyURLNetworkCodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for wrapped in [false, true] {
            for code in [URLError.Code.dataNotAllowed, .cancelled, .notConnectedToInternet, .init(rawValue: 123456)] {
                for isURLDomain in [false, true] {
                    let raw = URLError(
                        code,
                        userInfo: [
                            NSURLErrorNetworkUnavailableReasonKey: NSNumber(
                                value: URLError.NetworkUnavailableReason.expensive.rawValue)
                        ])
                    var serialized = Proton_Drive_Sdk_Error.from(nsError: raw as NSError)
                    #expect(!serialized.hasAdditionalData && !serialized.hasInnerError)
                    #expect(serialized.primaryCode == Int64(code.rawValue) || code == .cancelled)
                    if !isURLDomain {
                        serialized.type = "fixture-non-url"
                        serialized.domain = .network
                        serialized.primaryCode = Int64(code.rawValue)
                    }
                    if wrapped {
                        let inner = serialized
                        serialized = Proton_Drive_Sdk_Error.with {
                            $0.type = "fixture-outer"
                            $0.domain = .undefined
                            $0.message = "fixture"
                            $0.innerError = inner
                        }
                    }
                    let failure = ProtonDriveSDKError(protoError: serialized)
                    try await withBridge(
                        directory: directory,
                        operations: .init(
                            transfer: transfer(directory: directory), uploadTransport: { _, _, _ in throw failure })
                    ) { bridge in
                        let file = directory.appendingPathComponent("related.partial")
                        try Data("abc".utf8).write(to: file)
                        let upload = try request(file: file, allowsExpensiveNetwork: false)
                        let remote: any ExactDuplicateRemote = bridge
                        do {
                            _ = try await remote.uploadRelatedFile(upload)
                            Issue.record("An SDK failure must not return a UID")
                        } catch {
                            if isURLDomain && code == .cancelled {
                                #expect(error is CancellationError)
                            } else {
                                #expect(
                                    error as? ExactDuplicateRelatedFileTransferError
                                        == (isURLDomain && code == .dataNotAllowed
                                            ? .waitingForWiFi : .copyFailed(.transfer)))
                            }
                        }
                        #expect(!FileManager.default.fileExists(atPath: file.path))
                    }
                }
            }
        }
    }

    @Test func sdkFileSystemOutOfSpaceReachesThePrivateUploadAsCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for code in [POSIXErrorCode.ENOSPC, .EDQUOT, .EACCES] {
            for wrapped in [false, true] {
                var serialized = Proton_Drive_Sdk_Error.from(nsError: POSIXError(code) as NSError)
                if wrapped {
                    let inner = serialized
                    serialized = Proton_Drive_Sdk_Error.with {
                        $0.type = "fixture-outer"
                        $0.message = "fixture"
                        $0.domain = .undefined
                        $0.innerError = inner
                    }
                }
                let failure = ProtonDriveSDKError(protoError: serialized)
                let full = code != .EACCES
                #expect(failure.underlyingFileSystemErrorCode == (full ? .outOfSpace : .permissionDenied))
                let failures: [any Error] = wrapped ? [failure] : [failure, POSIXError(code)]
                for failure in failures {
                    let sink = RelatedFileLogSink()
                    try await withBridge(
                        directory: directory,
                        operations: .init(
                            transfer: transfer(directory: directory), uploadTransport: { _, _, _ in throw failure },
                            log: { sink.append($0) })
                    ) { bridge in
                        let file = directory.appendingPathComponent("related.partial")
                        try Data("abc".utf8).write(to: file)
                        let upload = try request(file: file, allowsExpensiveNetwork: false)
                        let remote: any ExactDuplicateRemote = bridge
                        await #expect(
                            throws: ExactDuplicateRelatedFileTransferError.copyFailed(full ? .capacity : .transfer)
                        ) {
                            try await remote.uploadRelatedFile(upload)
                        }
                        #expect(!FileManager.default.fileExists(atPath: file.path))
                        #expect(sink.lines.isEmpty)
                    }
                }
            }
        }
    }

    private func withBridge(
        directory: URL, operations: DriveSDKBridge.RelatedFileOperations,
        body: @Sendable (DriveSDKBridge) async throws -> Void
    ) async throws {
        let bridge = try await makeBridge(directory: directory, operations: operations)
        do {
            try await body(bridge)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        #expect(RelatedFileDenyHTTP.requestCount == 0)
    }

    private func request(
        file: URL, allowsExpensiveNetwork: Bool, name: String = "related.jpg"
    ) throws -> PhotoUploadRequest {
        let staged = try ExactDuplicateStagedFile.read(at: file)
        var request = PhotoUploadRequest(
            queueItemID: UploadQueueItemID(), cancellationToken: UUID(), fileURL: file,
            name: name, mediaType: "image/jpeg", fileSize: staged.fileSize,
            captureTime: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1),
            tags: [], expectedSHA1: staged.sha1, mainPhotoUID: PhotoUID(volumeID: "vol", nodeID: "kept"))
        request.allowsExpensiveNetwork = allowsExpensiveNetwork
        return request
    }

    private func transfer(
        directory: URL, network: LibraryNetworkState = .init()
    ) -> ExactDuplicateRelatedFileTransfer {
        ExactDuplicateRelatedFileTransfer(
            temporaryDirectory: directory, availableCapacity: { _ in 1024 }, networkState: { network })
    }

    private func makeBridge(
        directory: URL, operations: DriveSDKBridge.RelatedFileOperations
    ) async throws -> DriveSDKBridge {
        let governor = ProtonRequestGovernor()
        let session = makeSession(directory: directory, governor: governor)
        let client = try await makeSDKClient(session: session, governor: governor)
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let gate = TimelineMetadataStartGate()
        return DriveSDKBridge(
            prepared: DriveSDKBridge.PreparedSession(
                photosClient: client, uploadClientUID: "fixture", driveSession: session,
                requestGovernor: governor, expensiveUploadAccess: ExpensiveUploadAccess(),
                timelineStore: nil, timelineOrderStore: nil, firstIndexBuildGate: gate,
                metadataReconciliation: TimelineMetadataReconciliation(startGate: gate), crypto: crypto,
                photosVolumeBootstrap: PhotosVolumeBootstrapService(session: session, crypto: crypto),
                recentlyDeletedStore: RecentlyDeletedListingStore(
                    directory: directory, accountUID: "fixture", keyPassword: ""),
                photoNames: nil, recentlyDeleted: RecentlyDeletedIdentities(listing: nil),
                uploadManifestURL: directory.appendingPathComponent("manifest.sqlite"),
                uploadManifestPolicy: .conservative),
            relatedFileOperations: operations)
    }

    private func makeSession(directory: URL, governor: ProtonRequestGovernor) -> DriveSession {
        DriveSession(
            session: ProtonSession(uid: "related-fixture", accessToken: "", refreshToken: "", keyPassword: ""),
            store: SessionKeychainStore(
                service: "related-file-fixture", account: "fixture", keychain: RelatedFileDenyKeychain()),
            accountCacheDirectory: directory,
            requestGovernor: governor,
            urlProtocolClasses: [RelatedFileDenyHTTP.self])
    }

    private func makeSDKClient(
        session: DriveSession, governor: ProtonRequestGovernor
    ) async throws -> EncryptedMemoriesClient {
        try await EncryptedMemoriesClient(
            configuration: ProtonDriveClientConfiguration(baseURL: "https://fixture.invalid/", clientUID: "fixture"),
            httpClient: SDKHttpClient(
                driveSession: session, requestGovernor: governor, urlProtocolClasses: [RelatedFileDenyHTTP.self]),
            accountClient: SDKAccountClient(addresses: [], unlockedByKeyID: [:]),
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in })
    }
}

private final class RelatedFileDenyHTTP: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var requestCount: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private struct RelatedFileDenyKeychain: AppleKeychainStoring {
    func data(for item: AppleKeychainItem) throws -> Data? { throw CocoaError(.userCancelled) }
    func setData(_ data: Data, for item: AppleKeychainItem) throws { throw CocoaError(.userCancelled) }
    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data { throw CocoaError(.userCancelled) }
    func removeData(for item: AppleKeychainItem) throws { throw CocoaError(.userCancelled) }
    func removeAllData(service: String) throws { throw CocoaError(.userCancelled) }
}

private actor RelatedFileBridgeProbe {
    private(set) var sourceCount = 0
    private(set) var streamCount = 0
    func readSource() { sourceCount += 1 }
    func stream() { streamCount += 1 }
    private(set) var uploadCount = 0
    private(set) var reservation: UploadNetworkReservation?

    func upload(_ request: PhotoUploadRequest) -> PhotoUID {
        uploadCount += 1
        reservation = request.networkReservation
        #expect(reservation?.isActive == true)
        #expect(reservation?.allowsExpensiveNetwork == request.allowsExpensiveNetwork)
        #expect(request.mainPhotoUID == PhotoUID(volumeID: "vol", nodeID: "kept"))
        return PhotoUID(volumeID: "vol", nodeID: "copied")
    }
}

private final class RelatedFileBlockHTTP: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Bool] = []
    static var policies: [Bool] { lock.withLock { recorded } }
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    static func reset(routes: [String: Data] = [:]) {
        lock.withLock {
            recorded = []
            responses = routes
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request.allowsExpensiveNetworkAccess) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Self.lock.withLock { Self.responses[request.url!.path] ?? Data("abc".utf8) }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RelatedFileLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var lines: [String] { lock.withLock { messages } }
    func append(_ line: String) { lock.withLock { messages.append(line) } }
}

private let relatedStreamCryptoReady: Void = { injectDefaultCryptoImplementation() }()

private actor RelatedFileStreamBytes {
    private(set) var data = Data()
    func append(_ bytes: Data) { data.append(bytes) }
}
