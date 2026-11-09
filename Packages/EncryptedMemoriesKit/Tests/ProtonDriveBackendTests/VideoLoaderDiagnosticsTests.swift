import AVFoundation
import Foundation
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoPatchedGoImplementation
import Testing

@testable import ProtonDriveBackend

/// The `VideoStream` diagnostic of the video resource loader never carries the identifier of a
/// video, like the player diagnostics.
@Suite("Video loader diagnostics", .serialized)
struct VideoLoaderDiagnosticsTests {
    @Test func loaderDiagnosticsWriteNoIdentifier() async throws {
        injectDefaultCryptoImplementation()
        let uid = PhotoUID(volumeID: "volume-secret-1", nodeID: "node-secret-2")
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 5, count: 32), "aes256"))
        let clear = Data(repeating: 7, count: 64)
        LoaderDiagnosticBlockURLProtocol.configure(try key.encrypt(CryptoGo.CryptoNewPlainMessage(clear)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.loader-diagnostics.unused"), accountCacheDirectory: root,
            urlProtocolClasses: [LoaderDiagnosticBlockURLProtocol.self])
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let blocks = (1...10).map { index in
            VideoBlock(
                index: index, url: "https://example.invalid/block/\(index)", token: nil,
                clearOffset: (index - 1) * clear.count, clearSize: clear.count)
        }
        let prepared = PreparedVideo(
            uid: uid, totalSize: blocks.count * clear.count, contentTypeUTI: "public.movie",
            blocks: blocks, sessionKey: key)
        let events = DiagnosticEventBox()
        let loader = ProtonVideoResourceLoader(
            prepared: prepared, source: source, crypto: crypto, admission: JoinedShutdownGate(),
            cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent("blocks")),
            diagnostics: { name, fields in events.append(name: name, fields: fields) })
        defer { loader.close() }
        // Ten blocks put the sizing emit over the default deep window, so the loader schedules
        // read-ahead, opening prefetch, and a real byte-range request through the diagnostics seam.
        loader.useReadAhead(forPlaybackDuration: 1)
        loader.primePlaybackStart()
        let asset = AVURLAsset(url: URL(string: "protonvideo://diagnostics/loader.mov")!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tests.loader-diagnostics"))
        let load = Task { _ = try? await asset.load(.duration) }
        defer {
            asset.cancelLoading()
            load.cancel()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !events.strategies.isSuperset(of: ["readAhead", "range", "prefetch"]),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let all = events.all
        #expect(all.contains { $0.fields["strategy"] == "readAhead" }, "the read-ahead event was observed")
        #expect(all.contains { $0.fields["strategy"] == "range" }, "the range event was observed")
        #expect(all.contains { $0.fields["strategy"] == "prefetch" }, "the prefetch event was observed")
        for event in all {
            #expect(event.name == "VideoStream", "\(event.name)")
            #expect(event.fields["uid"] == nil, "\(event.fields)")
            for value in event.fields.values {
                #expect(!value.contains(uid.volumeID) && !value.contains(uid.nodeID), "\(value)")
            }
        }
    }

    /// The error events of the deep-warm and prefetch strategies report only the error's type,
    /// never its description: a `URLError` description carries the failing block URL, and a URL
    /// component cannot be proven free of identifiers.
    @Test func loaderDiagnosticsErrorsCarryOnlyTheErrorType() async throws {
        injectDefaultCryptoImplementation()
        let uid = PhotoUID(volumeID: "volume-secret-1", nodeID: "node-secret-2")
        let key = try #require(CryptoGo.CryptoNewSessionKeyFromToken(Data(repeating: 5, count: 32), "aes256"))
        let clear = Data(repeating: 7, count: 64)
        // Ten blocks keep read-ahead over the hot window, so blocks past it are deep-warmed; the
        // deep blocks answer HTTP 500, which fails both the deep warm and the opening tail
        // prefetch while the head blocks still serve bytes.
        LoaderDiagnosticBlockURLProtocol.configure(
            try key.encrypt(CryptoGo.CryptoNewPlainMessage(clear)), failingBlockIndices: [9, 10])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DriveSession(
            session: ProtonSession(uid: "test", accessToken: "test", refreshToken: "test", keyPassword: "test"),
            store: SessionKeychainStore(service: "tests.loader-diagnostics.unused"), accountCacheDirectory: root,
            urlProtocolClasses: [LoaderDiagnosticBlockURLProtocol.self])
        let crypto = DriveCrypto(addressKeys: [], signers: [])
        let source = PhotoVideoStreamSource(session: session, crypto: crypto, shareID: "test")
        let blocks = (1...10).map { index in
            VideoBlock(
                index: index, url: "https://example.invalid/block/\(index)", token: nil,
                clearOffset: (index - 1) * clear.count, clearSize: clear.count)
        }
        let prepared = PreparedVideo(
            uid: uid, totalSize: blocks.count * clear.count, contentTypeUTI: "public.movie",
            blocks: blocks, sessionKey: key)
        let events = DiagnosticEventBox()
        let loader = ProtonVideoResourceLoader(
            prepared: prepared, source: source, crypto: crypto, admission: JoinedShutdownGate(),
            cache: VideoByteRangeCache(rootDirectory: root.appendingPathComponent("blocks")),
            diagnostics: { name, fields in events.append(name: name, fields: fields) })
        defer { loader.close() }
        loader.useReadAhead(forPlaybackDuration: 1)
        loader.primePlaybackStart()
        let asset = AVURLAsset(url: URL(string: "protonvideo://diagnostics/loader.mov")!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tests.loader-diagnostics"))
        let load = Task { _ = try? await asset.load(.duration) }
        defer {
            asset.cancelLoading()
            load.cancel()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(events.hasErrored(strategy: "deepWarm") && events.hasErrored(strategy: "prefetch")),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let all = events.all
        #expect(!events.strategies.isEmpty, "\(events.strategies)")
        #expect(
            all.contains { $0.fields["strategy"] == "deepWarm" && $0.fields["error"] != nil },
            "the deep-warm error event was observed")
        #expect(
            all.contains { $0.fields["strategy"] == "prefetch" && $0.fields["error"] != nil },
            "the prefetch error event was observed")
        for event in all {
            #expect(event.name == "VideoStream", "\(event.name)")
            #expect(event.fields["uid"] == nil, "\(event.fields)")
            for value in event.fields.values {
                #expect(!value.contains(uid.volumeID) && !value.contains(uid.nodeID), "\(value)")
                // An interpolated error description would carry `block fetch HTTP 500`.
                #expect(!value.contains("block fetch"), "\(value)")
            }
        }
    }
}

/// Collects the loader events from several queues without losing any.
private final class DiagnosticEventBox: @unchecked Sendable {
    struct Event {
        let name: String
        let fields: [String: String]
    }
    private let lock = NSLock()
    private var stored: [Event] = []
    var all: [Event] { lock.withLock { stored } }
    var strategies: Set<String> { lock.withLock { Set(stored.compactMap { $0.fields["strategy"] }) } }
    func hasErrored(strategy: String) -> Bool {
        lock.withLock {
            stored.contains { $0.fields["strategy"] == strategy && $0.fields["error"] != nil }
        }
    }
    func append(name: String, fields: [String: String]) {
        lock.withLock { stored.append(Event(name: name, fields: fields)) }
    }
}

/// Answers requests with the configured encrypted bytes, like the streaming-lifetime fixture.
/// Configured block indices fail with HTTP 500, which `DriveSession.fetchBlock` reports as an
/// `apiError` whose message interpolates the status.
private final class LoaderDiagnosticBlockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bytes = Data()
    nonisolated(unsafe) private static var failingBlockIndices: Set<Int> = []
    static func configure(_ data: Data, failingBlockIndices: Set<Int> = []) {
        lock.withLock {
            self.bytes = data
            self.failingBlockIndices = failingBlockIndices
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, failing) = Self.lock.withLock { (Self.bytes, Self.failingBlockIndices) }
        let index = Int(request.url!.lastPathComponent) ?? -1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failing.contains(index) ? 500 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
