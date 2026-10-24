import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class ExactDuplicateRelatedFileTransferTests: XCTestCase {
    private var directory: URL!
    private var destination: URL { directory.appendingPathComponent("related.partial") }
    private let bytes = Data("abc".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func transfer(
        free: Int64? = 100, network: LibraryNetworkState = LibraryNetworkState(),
        stagingIO: RelatedFileStagingIO = .init()
    ) -> ExactDuplicateRelatedFileTransfer {
        ExactDuplicateRelatedFileTransfer(
            temporaryDirectory: directory, availableCapacity: { _ in free }, networkState: { network },
            stagingIO: stagingIO)
    }

    private func source(size: Int64? = 3) -> ExactDuplicateRelatedFileSource {
        ExactDuplicateRelatedFileSource(
            metadata: SeriesMemberSource(
                filename: "related.jpg", mediaType: "image/jpeg", captureTime: Date(timeIntervalSince1970: 1),
                modificationDate: Date(timeIntervalSince1970: 2), additionalMetadata: []),
            claimedSize: size)
    }

    private func request(digest: Data? = nil, file: URL? = nil) throws -> PhotoUploadRequest {
        let file = file ?? destination
        var request = PhotoUploadRequest(
            queueItemID: UploadQueueItemID(), cancellationToken: UUID(), fileURL: file,
            name: "related.jpg", mediaType: "image/jpeg", fileSize: Int64(bytes.count),
            captureTime: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 2),
            tags: [], expectedSHA1: try digest ?? UploadContentSHA1.digest(ofFileAt: file),
            mainPhotoUID: PhotoUID(volumeID: "vol", nodeID: "kept"))
        request.allowsExpensiveNetwork = false
        return request
    }

    func testDownloadAcceptsPrivateAndCanonicalTempPathsBeforeTheFileExists() async throws {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix("/var/"),
            FileManager.default.fileExists(atPath: "/private" + canonical.path)
        else { throw XCTSkip("The actual temporary directory has no /private alias on this platform") }
        let parent = canonical.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let source = source()
        let bytes = bytes
        for path in [parent.path, "/private" + parent.path] {
            let file = URL(fileURLWithPath: path).appendingPathComponent("related.partial")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let returned = try await transfer().download(
                to: file, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in try await consume(bytes) })
            XCTAssertEqual(returned, source.metadata)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testDownloadRejectsEscapingSymlinkParentsAndRelativeOrNonFileURLsBeforeReads() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let source = source()
        for file in [
            link.appendingPathComponent("related.partial"), URL(string: "related.partial")!,
            URL(string: "https://fixture.invalid/related.partial")!,
        ] {
            do {
                _ = try await transfer().download(
                    to: file, allowsExpensiveNetwork: false,
                    source: {
                        XCTFail("No metadata for a rejected path")
                        return source
                    }, stream: { _ in XCTFail("No stream for a rejected path") })
                XCTFail("A rejected path must fail")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testADanglingSymlinkDestinationIsRejectedBeforeNetworkAndMetadata() async throws {
        let target = directory.appendingPathComponent("missing-original")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let source = source()
        for network in [LibraryNetworkState(), .init(isExpensive: true)] {
            let reads = RelatedTransferProbe()
            let streams = RelatedTransferProbe()
            do {
                _ = try await transfer(network: network).download(
                    to: destination, allowsExpensiveNetwork: false,
                    source: {
                        await reads.hit()
                        return source
                    }, stream: { _ in await streams.hit() })
                XCTFail("A dangling destination link must fail")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination)) }
            let readCount = await reads.count
            let streamCount = await streams.count
            XCTAssertEqual(readCount, 0)
            XCTAssertEqual(streamCount, 0)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testFinishCloseErrorsReportCapacityOrStagingAndRemoveTheOwnedFile() async throws {
        let source = source()
        let bytes = bytes
        for code in [POSIXErrorCode.ENOSPC, .EDQUOT, .EIO] {
            do {
                _ = try await transfer(
                    stagingIO: .init(close: { handle in
                        try handle.close()
                        throw POSIXError(code)
                    })
                ).download(
                    to: destination, allowsExpensiveNetwork: false, source: { source },
                    stream: { consume in try await consume(bytes) })
                XCTFail("A failed finish close must not return metadata")
            } catch {
                XCTAssertEqual(
                    error as? ExactDuplicateRelatedFileTransferError,
                    .copyFailed(code == .EIO ? .staging : .capacity))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testUnderlyingCancellationPrecedesAnOuterWiFiRefusalOnBothRoutes() async throws {
        let source = source()
        let inner = NSError(
            domain: "fixture-wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        for code in [URLError.Code.dataNotAllowed, .notConnectedToInternet] {
            for cancelled in [false, true] {
                var info: [String: Any] = [:]
                if code == .notConnectedToInternet {
                    info[NSURLErrorNetworkUnavailableReasonKey] = NSNumber(
                        value: URLError.NetworkUnavailableReason.expensive.rawValue)
                }
                if cancelled { info[NSUnderlyingErrorKey] = inner }
                let error = URLError(code, userInfo: info)
                do {
                    _ = try await transfer().download(
                        to: destination, allowsExpensiveNetwork: false, source: { source },
                        stream: { _ in throw error })
                    XCTFail("A failed download must not return metadata")
                } catch {
                    if cancelled {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .waitingForWiFi)
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                try bytes.write(to: destination)
                let request = try request()
                do {
                    _ = try await transfer().upload(request) { _ in throw error }
                    XCTFail("A failed upload must not return a UID")
                } catch {
                    if cancelled {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .waitingForWiFi)
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    func testANilExpectedDigestRejectsTheUploadAndRemovesAcceptedStaging() async throws {
        try bytes.write(to: destination)
        let valid = try request()
        var missing = PhotoUploadRequest(
            queueItemID: valid.queueItemID, cancellationToken: valid.cancellationToken,
            fileURL: valid.fileURL, name: valid.name, mediaType: valid.mediaType, fileSize: valid.fileSize,
            captureTime: valid.captureTime, modificationDate: valid.modificationDate, tags: [],
            expectedSHA1: nil, mainPhotoUID: valid.mainPhotoUID)
        missing.allowsExpensiveNetwork = false
        do {
            _ = try await transfer().upload(missing) { _ in
                XCTFail("A nil expected digest must not reach the transport")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A nil expected digest must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.integrity)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadStagesExactlyTheClaimedBytesAndReturnsMetadata() async throws {
        let source = source()
        let bytes = bytes
        let returned = try await transfer().download(
            to: destination, allowsExpensiveNetwork: false, source: { source },
            stream: { consume in try await consume(bytes) })
        XCTAssertEqual(returned, source.metadata)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let facts = try ExactDuplicateStagedFile.read(at: destination)
        XCTAssertEqual(facts.fileSize, 3)
        XCTAssertEqual(UploadContentSHA1.hexString(digest: facts.sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testStagingReadMapsFilesystemErrorsWithoutPrivateDetails() throws {
        let missing = directory.appendingPathComponent("private-original.jpg")
        let rawError: NSError
        do {
            _ = try FileManager.default.attributesOfItem(atPath: missing.path)
            XCTFail("The fixture must produce a filesystem error")
            return
        } catch { rawError = error as NSError }
        XCTAssertThrowsError(try ExactDuplicateStagedFile.read(at: missing)) { error in
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging))
            let text = String(describing: error) + " " + error.localizedDescription
            XCTAssertFalse(text.contains(missing.lastPathComponent))
            XCTAssertFalse(text.contains(missing.path))
            XCTAssertFalse(text.contains(rawError.localizedDescription))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testStagingReadKeepsCancellation() async {
        let missing = directory.appendingPathComponent("private-original.jpg")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try ExactDuplicateStagedFile.read(at: missing) }
        }
        switch await task.value {
        case .success: XCTFail("A cancelled hash read must not return file facts")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testUnknownOrInsufficientCapacityNeverStartsTheDownload() async throws {
        for free in [nil, -1, 2] as [Int64?] {
            let probe = RelatedTransferProbe()
            let source = source()
            do {
                _ = try await transfer(free: free).download(
                    to: destination, allowsExpensiveNetwork: false, source: { source },
                    stream: { _ in await probe.hit() })
                XCTFail("A download without enough known capacity must fail")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.capacity)) }
            let calls = await probe.count
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testMissingOrNegativeClaimedSizeNeverStartsTheDownload() async throws {
        for size in [nil, -1] as [Int64?] {
            let probe = RelatedTransferProbe()
            let source = source(size: size)
            do {
                _ = try await transfer().download(
                    to: destination, allowsExpensiveNetwork: false, source: { source },
                    stream: { _ in await probe.hit() })
                XCTFail("A download without a valid claimed size must fail")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.size)) }
            let calls = await probe.count
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testAnExistingDestinationIsNeverReadOrOverwritten() async throws {
        let original = Data("existing".utf8)
        try original.write(to: destination)
        let probe = RelatedTransferProbe()
        let source = source()
        do {
            _ = try await transfer().download(
                to: destination, allowsExpensiveNetwork: false,
                source: {
                    await probe.hit()
                    return source
                }, stream: { _ in XCTFail("No download") })
            XCTFail("An existing destination must be rejected")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination)) }
        let calls = await probe.count
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testADestinationCreatedDuringTheMetadataReadIsNeverOverwritten() async throws {
        let destination = destination
        let original = Data("existing".utf8)
        let source = source()
        do {
            _ = try await transfer().download(
                to: destination, allowsExpensiveNetwork: false,
                source: {
                    try original.write(to: destination)
                    return source
                },
                stream: { _ in XCTFail("No download") })
            XCTFail("Exclusive creation must reject the intervening file")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination)) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testAnExpensiveOrUnknownPathWaitsWithoutReadingOrDownloading() async throws {
        for network in [LibraryNetworkState(isExpensive: true), .undetermined] {
            let probe = RelatedTransferProbe()
            let source = source()
            do {
                _ = try await transfer(network: network).download(
                    to: destination, allowsExpensiveNetwork: false,
                    source: {
                        await probe.hit()
                        return source
                    }, stream: { _ in XCTFail("No download") })
                XCTFail("A Wi-Fi-only copy must wait")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .waitingForWiFi) }
            let calls = await probe.count
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testExplicitMobileDataAndConstrainedWiFiRemainAllowed() async throws {
        let source = source()
        let bytes = bytes
        for (network, allowed) in [
            (LibraryNetworkState(isExpensive: true), true),
            (LibraryNetworkState(isConstrained: true), false),
        ] {
            _ = try await transfer(network: network).download(
                to: destination, allowsExpensiveNetwork: allowed, source: { source },
                stream: { consume in try await consume(bytes) })
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testShortOrLongStreamsFailAndRemoveStaging() async throws {
        let source = source()
        for bytes in [Data("ab".utf8), Data("abcd".utf8)] {
            let probe = RelatedTransferProbe()
            do {
                _ = try await transfer().download(
                    to: destination, allowsExpensiveNetwork: false, source: { source },
                    stream: { consume in
                        try await consume(bytes)
                        await probe.hit()
                    })
                XCTFail("A stream must match its claimed size")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.size)) }
            let calls = await probe.count
            XCTAssertEqual(calls, bytes.count < 3 ? 1 : 0, "An oversized chunk stops its producer at the write")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testAStreamFailureRemovesThePartialStagingFile() async throws {
        let source = source()
        do {
            _ = try await transfer().download(
                to: destination, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in
                    try await consume(Data("a".utf8))
                    throw URLError(.networkConnectionLost)
                })
            XCTFail("The stream failure must propagate")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.transfer)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellingTheDownloadRemovesStagingInsteadOfReturningMetadata() async throws {
        let source = source()
        let bytes = bytes
        let transfer = transfer()
        let destination = destination
        let started = expectation(description: "stream started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let task = Task {
            try await transfer.download(
                to: destination, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in
                    try await consume(bytes)
                    started.fulfill()
                    for await _ in gate.stream {}
                })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return metadata")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUploadPreservesRequestValuesAndCleansStagingAfterSuccess() async throws {
        try bytes.write(to: destination)
        let request = try request()
        let copied = PhotoUID(volumeID: "vol", nodeID: "copied")
        let uid = try await transfer().upload(request) { received in
            XCTAssertEqual(received.fileSize, 3)
            XCTAssertEqual(received.expectedSHA1, request.expectedSHA1)
            XCTAssertEqual(received.mainPhotoUID, request.mainPhotoUID)
            XCTAssertFalse(received.allowsExpensiveNetwork)
            return copied
        }
        XCTAssertEqual(uid, copied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUploadFailureAndWiFiWaitBothRemoveStaging() async throws {
        for expensive in [false, true] {
            try bytes.write(to: destination)
            let request = try request()
            let probe = RelatedTransferProbe()
            do {
                _ = try await transfer(network: .init(isExpensive: expensive)).upload(request) { _ in
                    await probe.hit()
                    throw URLError(.networkConnectionLost)
                }
                XCTFail("Upload must fail")
            } catch {
                XCTAssertEqual(
                    error as? ExactDuplicateRelatedFileTransferError,
                    expensive ? .waitingForWiFi : .copyFailed(.transfer))
            }
            let calls = await probe.count
            XCTAssertEqual(calls, expensive ? 0 : 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testWrongDigestSizeOrMissingMainIsRejectedBeforeUpload() async throws {
        for invalid in 0..<3 {
            try bytes.write(to: destination)
            let request = try request(digest: Data(repeating: 0, count: 20))
            let correctDigest = try UploadContentSHA1.digest(ofFileAt: destination)
            var bad = PhotoUploadRequest(
                queueItemID: request.queueItemID, cancellationToken: request.cancellationToken,
                fileURL: request.fileURL, name: request.name, mediaType: request.mediaType,
                fileSize: invalid == 1 ? 4 : 3, captureTime: request.captureTime,
                modificationDate: request.modificationDate, tags: [],
                expectedSHA1: invalid == 0 ? request.expectedSHA1 : correctDigest,
                mainPhotoUID: invalid == 2 ? nil : request.mainPhotoUID)
            bad.allowsExpensiveNetwork = false
            let probe = RelatedTransferProbe()
            do {
                _ = try await transfer().upload(bad) { _ in
                    await probe.hit()
                    return PhotoUID(volumeID: "vol", nodeID: "unexpected")
                }
                XCTFail("Invalid content or missing kept main must fail")
            } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.integrity)) }
            let calls = await probe.count
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testZeroSizeStillRequiresKnownCapacityAndCreatesAnEmptyFile() async throws {
        let source = source(size: 0)
        _ = try await transfer(free: 0).download(
            to: destination, allowsExpensiveNetwork: false, source: { source }, stream: { _ in })
        let facts = try ExactDuplicateStagedFile.read(at: destination)
        XCTAssertEqual(facts.fileSize, 0)
        XCTAssertEqual(UploadContentSHA1.hexString(digest: facts.sha1), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testADestinationOutsideTheConfiguredTempStoreIsRejectedWithoutReads() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = source()
        do {
            _ = try await transfer().download(
                to: other, allowsExpensiveNetwork: false,
                source: {
                    XCTFail("No metadata read")
                    return source
                }, stream: { _ in XCTFail("No download") })
            XCTFail("An outside path must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testAnUnreachablePathFailsWithoutCreatingStaging() async throws {
        let source = source()
        do {
            _ = try await transfer(network: .init(isReachable: false)).download(
                to: destination, allowsExpensiveNetwork: true,
                source: {
                    XCTFail("No metadata read")
                    return source
                }, stream: { _ in XCTFail("No download") })
            XCTFail("An unreachable path must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.transfer)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTransportWiFiRefusalMapsToWaitingAndRemovesStaging() async throws {
        try bytes.write(to: destination)
        let request = try request()
        do {
            _ = try await transfer().upload(request) { _ in throw URLError(.dataNotAllowed) }
            XCTFail("A transport Wi-Fi refusal must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .waitingForWiFi) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testADataRefusalWithMobileDataEnabledIsACopyFailure() async throws {
        try bytes.write(to: destination)
        var request = try request()
        request.allowsExpensiveNetwork = true
        do {
            _ = try await transfer().upload(request) { _ in throw URLError(.dataNotAllowed) }
            XCTFail("A refused upload must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.transfer)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellingTheUploadRemovesStagingAndReturnsNoUID() async throws {
        try bytes.write(to: destination)
        let request = try request()
        let transfer = transfer()
        let started = expectation(description: "upload started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let task = Task {
            try await transfer.upload(request) { _ in
                started.fulfill()
                for await _ in gate.stream {}
                return PhotoUID(volumeID: "vol", nodeID: "copied")
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a UID")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testASymlinkUploadIsRejectedAndLeavesItsTargetUntouched() async throws {
        let target = directory.appendingPathComponent("original")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let request = try request()
        XCTAssertThrowsError(try ExactDuplicateStagedFile.read(at: destination))
        do {
            _ = try await transfer().upload(request) { _ in
                XCTFail("A symlink must not upload")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A symlink must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
    }

    func testACleanupFailureIsReportedInsteadOfReturningASourceOrUID() async throws {
        let source = source()
        let directory = directory!
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        do {
            _ = try await transfer().download(
                to: destination, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in
                    try await consume(Data("a".utf8))
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                    throw URLError(.networkConnectionLost)
                })
            XCTFail("A failed cleanup must fail the copy")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.cleanup)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try bytes.write(to: destination)
        let request = try request()
        do {
            _ = try await transfer().upload(request) { _ in
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                return PhotoUID(volumeID: "vol", nodeID: "copied")
            }
            XCTFail("A failed cleanup must not return a UID")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.cleanup)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSystemNetworkErrorsKeepTheirMeaningForDownloadAndUpload() async throws {
        let source = source()
        for wrapped in [false, true] {
            for code in [URLError.Code.dataNotAllowed, .cancelled, .notConnectedToInternet] {
                for reason in [nil, .expensive, .constrained] as [URLError.NetworkUnavailableReason?] {
                    var info: [String: Any] = [:]
                    if let reason { info[NSURLErrorNetworkUnavailableReasonKey] = NSNumber(value: reason.rawValue) }
                    let raw = URLError(code, userInfo: info)
                    XCTAssertEqual(raw.networkUnavailableReason, reason)
                    let error: any Error =
                        wrapped
                        ? NSError(domain: "fixture-wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: raw]) : raw
                    for allowed in [false, true] {
                        do {
                            _ = try await transfer().download(
                                to: destination, allowsExpensiveNetwork: allowed, source: { source },
                                stream: { _ in throw error })
                            XCTFail("A failed download must not return metadata")
                        } catch {
                            assertNetworkError(error, code: code, reason: reason, allowed: allowed)
                        }
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                        try bytes.write(to: destination)
                        var upload = try request()
                        upload.allowsExpensiveNetwork = allowed
                        do {
                            _ = try await transfer().upload(upload) { _ in throw error }
                            XCTFail("A failed upload must not return a UID")
                        } catch {
                            assertNetworkError(error, code: code, reason: reason, allowed: allowed)
                        }
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                    }
                }
            }
        }
    }

    private func assertNetworkError(
        _ error: any Error, code: URLError.Code, reason: URLError.NetworkUnavailableReason?, allowed: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if code == .cancelled {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        } else {
            let waits = !allowed && (code == .dataNotAllowed || reason == .expensive)
            XCTAssertEqual(
                error as? ExactDuplicateRelatedFileTransferError,
                waits ? .waitingForWiFi : .copyFailed(.transfer), file: file, line: line)
        }
    }

    func testUploadRejectsAnOutsideFileWithoutDeletingIt() async throws {
        let outside = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        .appendingPathComponent("related-transfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try bytes.write(to: outside)
        let upload = try request(file: outside)
        do {
            _ = try await transfer().upload(upload) { _ in
                XCTFail("A rejected file must not upload")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("An outside file must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }

    func testUploadRejectsAConfiguredStoreOutsideAppTempWithoutDeletingItsFile() async throws {
        let store = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        .appendingPathComponent("related-transfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        let file = store.appendingPathComponent("related.partial")
        try bytes.write(to: file)
        let appTemp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertFalse(file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(appTemp + "/"))
        let transfer = ExactDuplicateRelatedFileTransfer(
            temporaryDirectory: store, networkState: { LibraryNetworkState() })
        let upload = try request(file: file)
        do {
            _ = try await transfer.upload(upload) { _ in
                XCTFail("A file outside app temp must not upload even inside the configured store")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A configured store outside app temp must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testUnreadableUploadAttributesPreserveTheUnownedFileAndCancellation() async throws {
        let parent = directory.appendingPathComponent("private-store")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let file = parent.appendingPathComponent("private-original.jpg")
        try bytes.write(to: file)
        let upload = try request(file: file)
        let transfer = transfer()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        XCTAssertThrowsError(try FileManager.default.attributesOfItem(atPath: file.path))
        for cancelled in [false, true] {
            let task = Task {
                if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    _ = try await transfer.upload(upload) { _ in
                        XCTFail("An unreadable unowned file must not upload")
                        return PhotoUID(volumeID: "vol", nodeID: "unexpected")
                    }
                    XCTFail("Unreadable attributes must fail")
                } catch {
                    if cancelled {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.transfer))
                    }
                    XCTAssertFalse(String(describing: error).contains(file.path))
                    XCTAssertFalse(String(describing: error).contains(file.lastPathComponent))
                }
            }
            await task.value
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAnExclusiveCreatePermissionFailureReportsStagingWithoutStartingTheStream() async throws {
        let parent = directory!
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let file = destination
        let source = source()
        do {
            _ = try await transfer().download(
                to: file, allowsExpensiveNetwork: false,
                source: {
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
                    return source
                }, stream: { _ in XCTFail("A failed exclusive create must not start a stream") })
            XCTFail("A denied exclusive create must fail")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging))
            XCTAssertFalse(String(describing: error).contains(file.path))
            XCTAssertFalse(String(describing: error).contains(file.lastPathComponent))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testADirectoryCreatedDuringMetadataIsRejectedUntouched() async throws {
        let file = destination
        let source = source()
        let sentinel = file.appendingPathComponent("untouched")
        let bytes = bytes
        do {
            _ = try await transfer().download(
                to: file, allowsExpensiveNetwork: false,
                source: {
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                    try bytes.write(to: sentinel)
                    return source
                }, stream: { _ in XCTFail("No stream into an intervening directory") })
            XCTFail("An intervening directory must fail")
        } catch {
            XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination))
            XCTAssertFalse(String(describing: error).contains(file.path))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }

    func testUploadRejectsANonFileURLWithoutInvokingTheTransport() async throws {
        let upload = try request(
            digest: Data(repeating: 0, count: 20), file: URL(string: "https://fixture.invalid/file")!)
        do {
            _ = try await transfer().upload(upload) { _ in
                XCTFail("A non-file URL must not upload")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A non-file URL must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testUploadRejectsADirectoryWithoutDeletingIt() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let upload = try request(digest: Data(repeating: 0, count: 20))
        do {
            _ = try await transfer().upload(upload) { _ in
                XCTFail("A directory must not upload")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A directory must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAMissingParentIsAStagingFailureWithoutStartingTheStream() async throws {
        let source = source()
        let missing = directory.appendingPathComponent("missing/related.partial")
        do {
            _ = try await transfer().download(
                to: missing, allowsExpensiveNetwork: false, source: { source },
                stream: { _ in XCTFail("No stream without a staging file") })
            XCTFail("A missing parent must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testCleanupOfAnAlreadyAbsentUploadFileSucceeds() async throws {
        try bytes.write(to: destination)
        let upload = try request()
        let file = destination
        let copied = PhotoUID(volumeID: "vol", nodeID: "copied")
        let result = try await transfer().upload(upload) { _ in
            try FileManager.default.removeItem(at: file)
            return copied
        }
        XCTAssertEqual(result, copied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPreCancelledDownloadAndUploadNeverStartTransferAndCleanOwnedStaging() async throws {
        let transfer = transfer()
        let source = source()
        let file = destination
        let download = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transfer.download(
                to: file, allowsExpensiveNetwork: false,
                source: {
                    XCTFail("No source read after cancellation")
                    return source
                },
                stream: { _ in XCTFail("No stream after cancellation") })
        }
        do {
            _ = try await download.value
            XCTFail("A cancelled download must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try bytes.write(to: file)
        let request = try request()
        let upload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transfer.upload(request) { _ in
                XCTFail("No upload after cancellation")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
        }
        do {
            _ = try await upload.value
            XCTFail("A cancelled upload must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testASymlinkCreatedDuringMetadataIsRejectedUntouched() async throws {
        let target = directory.appendingPathComponent("original")
        try bytes.write(to: target)
        let file = destination
        let source = source()
        do {
            _ = try await transfer().download(
                to: file, allowsExpensiveNetwork: false,
                source: {
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                    return source
                }, stream: { _ in XCTFail("No stream into an existing symlink") })
            XCTFail("An intervening symlink must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination)) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testAnExistingSymlinkDestinationIsRejectedUntouched() async throws {
        let target = directory.appendingPathComponent("original")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let source = source()
        do {
            _ = try await transfer().download(
                to: destination, allowsExpensiveNetwork: false,
                source: {
                    XCTFail("No metadata for an existing destination")
                    return source
                },
                stream: { _ in XCTFail("No stream into an existing symlink") })
            XCTFail("An existing symlink must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.destination)) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testCancellationDuringFinishRemovesStagingAndReturnsNoMetadata() async throws {
        let transfer = transfer(
            stagingIO: .init(close: { handle in
                try handle.close()
                withUnsafeCurrentTask { $0?.cancel() }
            }))
        let source = source()
        let file = destination
        let bytes = bytes
        let task = Task {
            try await transfer.download(
                to: file, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in try await consume(bytes) })
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation during finish must not return metadata")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testALateWriteAfterFinishReportsStagingFailure() async throws {
        let consumer = RelatedTransferConsumer()
        let source = source()
        let bytes = bytes
        _ = try await transfer().download(
            to: destination, allowsExpensiveNetwork: false, source: { source },
            stream: { consume in
                await consumer.store(consume)
                try await consume(bytes)
            })
        do {
            try await consumer.append(Data("late".utf8))
            XCTFail("A finished writer must reject late writes")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testAWriteThatRunsOutOfSpaceReportsCapacityAndCleansStaging() async throws {
        let source = source()
        let bytes = bytes
        do {
            _ = try await transfer(stagingIO: .init(write: { _, _ in throw POSIXError(.ENOSPC) })).download(
                to: destination, allowsExpensiveNetwork: false, source: { source },
                stream: { consume in try await consume(bytes) })
            XCTFail("A full-disk write must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.capacity)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAWriterCloseFailureDuringCleanupReturnsCleanupFailure() async throws {
        let source = source()
        do {
            _ = try await transfer(
                stagingIO: .init(close: { handle in
                    try handle.close()
                    throw POSIXError(.EIO)
                })
            ).download(
                to: destination, allowsExpensiveNetwork: false, source: { source },
                stream: { _ in throw URLError(.networkConnectionLost) })
            XCTFail("A failed cleanup must not return metadata")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.cleanup)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheDefaultWriterPropagatesFilesystemWriteErrors() throws {
        try bytes.write(to: destination)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        XCTAssertThrowsError(try RelatedFileStagingIO().write(handle, bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testTheDefaultCloserClosesItsDescriptor() throws {
        try bytes.write(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try RelatedFileStagingIO().close(handle)
        XCTAssertThrowsError(try handle.write(contentsOf: bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testAMissingParentWithTheProductionCapacityQueryIsAStagingFailure() async throws {
        let source = source()
        let transfer = ExactDuplicateRelatedFileTransfer(temporaryDirectory: directory, networkState: { .init() })
        do {
            _ = try await transfer.download(
                to: directory.appendingPathComponent("missing/related.partial"), allowsExpensiveNetwork: false,
                source: { source }, stream: { _ in XCTFail("No stream without a parent") })
            XCTFail("A missing parent must fail")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.staging)) }
    }

    func testACallerReservationIsRejectedWithoutReleasingItsOwnersReservation() async throws {
        try bytes.write(to: destination)
        var request = try request()
        let admission = UploadNetworkAdmission()
        let reservation = try await admission.reserve(allowsExpensiveNetwork: false)
        defer { reservation.release() }
        request.networkReservation = reservation
        do {
            _ = try await transfer().upload(request) { _ in
                XCTFail("The bridge must reserve its own network")
                return PhotoUID(volumeID: "vol", nodeID: "unexpected")
            }
            XCTFail("A caller reservation must be rejected")
        } catch { XCTAssertEqual(error as? ExactDuplicateRelatedFileTransferError, .copyFailed(.integrity)) }
        XCTAssertTrue(reservation.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private actor RelatedTransferProbe {
    private(set) var count = 0
    func hit() { count += 1 }
}

private actor RelatedTransferConsumer {
    private var consume: ExactDuplicateRelatedFileTransfer.ByteConsumer?
    func store(_ consume: @escaping ExactDuplicateRelatedFileTransfer.ByteConsumer) { self.consume = consume }
    func append(_ data: Data) async throws {
        guard let consume else {
            XCTFail("The stream must supply a consumer")
            return
        }
        try await consume(data)
    }
}
