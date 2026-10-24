import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import MLSearchCore
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter

/// Adapter tests that do not require a model artifact. A local opt-in smoke covers the real model.
@Suite struct MLSearchAppleAdapterTests {
    private final class WakeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }

        func reaches(_ target: Int) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while value < target, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return value >= target
        }
    }

    private actor EmptyThumbnailLoader: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult { .delivered }
    }

    private enum GateSignal: CaseIterable, Sendable {
        case thermal, lowPower, playback, search, userTransfer

        func setActive(_ active: Bool, in snapshot: inout LibraryRuntimeSnapshot) {
            switch self {
            case .thermal: snapshot.thermalLevel = active ? .critical : .nominal
            case .lowPower: snapshot.isLowPowerMode = active
            case .playback: snapshot.activeVideoPlaybackCount = active ? 1 : 0
            case .search: snapshot.activeSearchCount = active ? 1 : 0
            case .userTransfer: snapshot.activeUserTransferCount = active ? 1 : 0
            }
        }
    }

    private final class DemandState: @unchecked Sendable {
        private let lock = NSLock()
        private var active: Bool
        private var refreshes: [@Sendable () -> Void] = []

        init(active: Bool) {
            self.active = active
        }

        func isActive() -> Bool {
            lock.withLock { active }
        }

        func setActive(_ active: Bool) {
            lock.withLock { self.active = active }
        }

        func schedule(_ refresh: @escaping @Sendable () -> Void) {
            lock.withLock { refreshes.append(refresh) }
        }

        func runNextRefresh() -> Bool {
            let refresh = lock.withLock {
                refreshes.isEmpty ? nil : refreshes.removeFirst()
            }
            refresh?()
            return refresh != nil
        }

        var scheduledRefreshCount: Int {
            lock.withLock { refreshes.count }
        }
    }

    private struct FixedImageSource: CoreMLImageSource {
        let image: CoreMLSourceImage

        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
            .image(image)
        }
    }

    private let descriptor = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 4)
    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func block(_ vectors: [(String, [Float32])]) -> MLVectorBlock {
        var block = MLVectorBlock(descriptor: descriptor)
        for (id, vector) in vectors {
            block.append(uid: uid(id), vector: ContiguousArray(vector))
        }
        return block
    }

    @Test func smartSearchWorkGateYieldsForVisibleMediaDemand() {
        let runtimeState = LibraryRuntimeState()
        let idle = AppleSmartSearchWorkGate(
            visibleMediaDemandActive: { false }, runtimeState: runtimeState
        )
        #expect(idle.permitsIndexing())

        let visibleDemand = AppleSmartSearchWorkGate(
            visibleMediaDemandActive: { true }, runtimeState: runtimeState
        )
        #expect(visibleDemand.permitsIndexing() == false)

        let hostBlocked = AppleSmartSearchWorkGate(
            visibleMediaDemandActive: { false },
            runtimeState: runtimeState,
            hostPermitsIndexing: { false }
        )
        #expect(hostBlocked.permitsIndexing() == false)
    }

    @Test func smartSearchWorkGateWakesIndexingWhenAnInputOpensTheGate() async throws {
        var initial = LibraryRuntimeSnapshot()
        initial.isLowPowerMode = true
        let runtimeState = LibraryRuntimeState(initial: initial)
        let gate = AppleSmartSearchWorkGate(visibleMediaDemandActive: { false }, runtimeState: runtimeState)
        let wakes = WakeCounter()
        gate.setIndexingWake { wakes.increment() }
        // The baseline is taken at registration, so this change wakes even if the observation starts later.
        runtimeState.update { $0.isLowPowerMode = false }
        #expect(await wakes.reaches(1))
        withExtendedLifetime(gate) {}
    }

    @Test func gateWakePolicyWakesOnlyForAnOpeningOfAClosedGate() {
        var policy = SmartSearchGateWakePolicy(permits: true)
        // A runtime change that leaves the open gate open, such as the network path, wakes nothing. A change that
        // closes the gate cannot start indexing. Only the change that opens the closed gate wakes, once.
        let wakes = [
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
            policy.runtimeChanged(permits: false, gateIsOpenNow: false),
            policy.runtimeChanged(permits: false, gateIsOpenNow: false),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(wakes == [false, false, false, true, false])
    }

    @Test func gateWakePolicyWakesForAReopenThatTheLoopSawClosed() {
        var policy = SmartSearchGateWakePolicy(permits: true)
        // The newest-only update stream merged the close with the reopen, so the update looks like no change.
        let wakes = [
            policy.loopFoundGateClosed(currentPermits: false),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(wakes == [false, true, false])
    }

    @Test func gateWakePolicyKeepsAClosedGateOfTheLoopClosedUntilItOpens() {
        var policy = SmartSearchGateWakePolicy(permits: true)
        let wakes = [
            policy.loopFoundGateClosed(currentPermits: false),
            policy.runtimeChanged(permits: false, gateIsOpenNow: false),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(wakes == [false, false, true])
    }

    @Test func gateWakePolicyWakesOnceWhenTheGateReopenedBeforeTheLoopRecordedItClosed() {
        // The observer saw the close; the loop then finds the gate open again and wakes. The update of that reopen
        // must not wake a second time.
        var observedClose = SmartSearchGateWakePolicy(permits: true)
        let afterClose = [
            observedClose.runtimeChanged(permits: false, gateIsOpenNow: false),
            observedClose.loopFoundGateClosed(currentPermits: true),
            observedClose.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(afterClose == [false, true, false])

        // The loop first recorded a closed gate, then found it open: the flag is gone and the reopen wakes once.
        var recordedFirst = SmartSearchGateWakePolicy(permits: true)
        let afterRecord = [
            recordedFirst.loopFoundGateClosed(currentPermits: false),
            recordedFirst.loopFoundGateClosed(currentPermits: true),
            recordedFirst.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(afterRecord == [false, true, false])
        #expect(recordedFirst.loopSawClosedGate == false)
    }

    @Test func gateWakePolicySuppressesAWakeAgainstAGateThatClosedAgain() {
        var policy = SmartSearchGateWakePolicy(permits: true)
        // The update opened the gate, but the gate is closed again: nothing to wake. The next opening wakes.
        let wakes = [
            policy.runtimeChanged(permits: false, gateIsOpenNow: false),
            policy.runtimeChanged(permits: true, gateIsOpenNow: false),
            policy.runtimeChanged(permits: false, gateIsOpenNow: false),
            policy.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(wakes == [false, false, false, true])

        // A gate that the loop saw closed keeps counting as closed after a suppressed wake.
        var seenByLoop = SmartSearchGateWakePolicy(permits: true)
        let seen = [
            seenByLoop.loopFoundGateClosed(currentPermits: false),
            seenByLoop.runtimeChanged(permits: true, gateIsOpenNow: false),
            seenByLoop.runtimeChanged(permits: true, gateIsOpenNow: true),
        ]
        #expect(seen == [false, false, true])
    }

    @Test(arguments: GateSignal.allCases)
    private func gateRecordsThatTheLoopFoundItClosed(signal: GateSignal) {
        var initial = LibraryRuntimeSnapshot()
        signal.setActive(true, in: &initial)
        let runtimeState = LibraryRuntimeState(initial: initial)
        let gate = AppleSmartSearchWorkGate(visibleMediaDemandActive: { false }, runtimeState: runtimeState)
        gate.setIndexingWake {}
        // The observer cannot clear this record: only a wake does, and a closed gate wakes nothing.
        #expect(gate.permitsIndexing() == false)
        #expect(gate.wakePolicyForTesting?.loopSawClosedGate == true)
    }

    @Test(arguments: GateSignal.allCases)
    private func publicWorkGateResumesForRuntimeInputsAndReplacesItsCallback(signal: GateSignal) async throws {
        var initial = LibraryRuntimeSnapshot()
        signal.setActive(true, in: &initial)
        let runtimeState = LibraryRuntimeState(initial: initial)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ThumbnailCache(namespace: "work-gate", rootDirectory: root)
        cache.configure(accountUID: "fixture", key: SymmetricKey(size: .bits256))
        let feed = ThumbnailFeedCore(cache: cache, loader: EmptyThumbnailLoader())
        var gate: AppleSmartSearchWorkGate? = AppleSmartSearchWorkGate(feed: feed, runtimeState: runtimeState)
        #expect(gate?.permitsIndexing() == false)
        let first = WakeCounter()
        gate?.setIndexingWake { first.increment() }
        runtimeState.update { signal.setActive(false, in: &$0) }
        try #require(await first.reaches(1))
        #expect(gate?.permitsIndexing() == true)

        let replacement = WakeCounter()
        gate?.setIndexingWake { replacement.increment() }
        // The loop sees the gate closed, then it opens again. The update stream may merge the two changes, so only
        // what the loop saw tells that the reopen needs a wake.
        runtimeState.update { signal.setActive(true, in: &$0) }
        #expect(gate?.permitsIndexing() == false)
        runtimeState.update { signal.setActive(false, in: &$0) }
        try #require(await replacement.reaches(1))
        #expect(first.value == 1)
        #expect(replacement.value == 1)
        #expect(gate?.permitsIndexing() == true)

        weak var releasedGate = gate
        gate = nil
        for _ in 0..<100 where releasedGate != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(releasedGate == nil)
    }

    @Test func smartSearchWorkGatePublishesDemandExpiryWithoutAnotherGatePoll() async throws {
        let runtimeState = LibraryRuntimeState()
        let demand = DemandState(active: true)
        let gate = AppleSmartSearchWorkGate(
            visibleMediaDemandActive: { demand.isActive() },
            runtimeState: runtimeState,
            scheduleDemandRefresh: { demand.schedule($0) }
        )

        #expect(gate.permitsIndexing() == false)
        #expect(runtimeState.snapshot().hasVisibleMediaDemand)
        #expect(demand.scheduledRefreshCount == 1)
        let wakes = WakeCounter()
        gate.setIndexingWake { wakes.increment() }
        #expect(gate.permitsIndexing() == false)
        #expect(demand.scheduledRefreshCount == 1)

        #expect(demand.runNextRefresh())
        #expect(runtimeState.snapshot().hasVisibleMediaDemand)
        #expect(demand.scheduledRefreshCount == 1)

        demand.setActive(false)
        #expect(demand.runNextRefresh())
        #expect(runtimeState.snapshot().hasVisibleMediaDemand == false)
        #expect(demand.scheduledRefreshCount == 0)
        #expect(await wakes.reaches(1))
    }

    @Test func tinyCLIPTokenizerMatchesReferenceVectors() throws {
        let tokenizer = try CLIPBPETokenizer.bundledTinyCLIP()

        let english = try tokenizer.tokenize("a photo of trees")
        #expect(Array(english.inputIDs.prefix(6)) == [49_406, 320, 1_125, 539, 4_682, 49_407])
        #expect(english.endTokenIndex == 5)
        #expect(english.inputIDs.count == 77)

        let german = try tokenizer.tokenize("Bäume")
        #expect(Array(german.inputIDs.prefix(6)) == [49_406, 65, 10_896, 84, 614, 49_407])
        #expect(german.endTokenIndex == 5)
    }

    @Test func tinyCLIPTokenizerNormalizesWhitespaceAndTruncatesSafely() throws {
        let tokenizer = try CLIPBPETokenizer.bundledTinyCLIP()
        let normalized = try tokenizer.tokenize("  A\nphoto\tOF trees  ")
        let reference = try tokenizer.tokenize("a photo of trees")
        #expect(normalized == reference)

        let long = try tokenizer.tokenize(String(repeating: "trees ", count: 200))
        #expect(long.inputIDs.count == 77)
        #expect(long.endTokenIndex == 76)
        #expect(long.inputIDs[76] == CLIPBPETokenizer.endTokenID)
    }

    @Test func coreMLTextInputsMarkOnlyTheSemanticEndToken() throws {
        let tokenized = MLTokenizedText(inputIDs: [49_406, 320, 49_407, 49_407], endTokenIndex: 2)
        let inputs = try CoreMLArrayCodec.textInputs(tokenized)

        #expect((0..<4).map { inputs.ids[$0].int32Value } == [49_406, 320, 49_407, 49_407])
        #expect((0..<4).map { inputs.endMask[$0].floatValue } == [0, 0, 1, 0])
    }

    @Test func coreMLArrayCodecReadsSupportedPrecisions() throws {
        let float32 = try MLMultiArray(shape: [3], dataType: .float32)
        float32[0] = 0.25
        float32[1] = -0.5
        float32[2] = 1
        #expect(try CoreMLArrayCodec.float32Values(from: float32) == [0.25, -0.5, 1])

        let float16 = try MLMultiArray(shape: [2], dataType: .float16)
        float16[0] = 0.5
        float16[1] = -1
        #expect(try CoreMLArrayCodec.float32Values(from: float16) == [0.5, -1])

        let double = try MLMultiArray(shape: [2], dataType: .double)
        double[0] = 0.75
        double[1] = -0.25
        #expect(try CoreMLArrayCodec.float32Values(from: double) == [0.75, -0.25])
    }

    @Test func float16BitConversionIsArchitectureIndependent() {
        #expect(CoreMLArrayCodec.float32(fromIEEE754Half: 0x3c00) == 1)
        #expect(CoreMLArrayCodec.float32(fromIEEE754Half: 0xc000) == -2)
        #expect(abs(CoreMLArrayCodec.float32(fromIEEE754Half: 0x0001) - 0.000000059604645) < 1e-12)
        #expect(CoreMLArrayCodec.float32(fromIEEE754Half: 0x7c00).isInfinite)
    }

    @Test func cachedThumbnailSourceReturnsImageWithoutOwningFetchPolicy() async throws {
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        let image = try #require(context.makeImage())
        let hit = CachedThumbnailMLImageSource(load: { _ in CoreMLSourceImage(cgImage: image) })
        let miss = CachedThumbnailMLImageSource(load: { _ in nil })

        guard case .image(let loaded) = await hit.image(for: uid("hit")) else {
            Issue.record("Expected cached image")
            return
        }
        #expect(loaded.cgImage.width == 2)
        guard case .transientFailure = await miss.image(for: uid("miss")) else {
            Issue.record("A cache miss must remain retryable")
            return
        }

        let rejected = CachedThumbnailMLImageSource(resolve: { _ in
            .permanentFailure(reason: CachedThumbnailMLImageSourceFailureReason.unavailable.rawValue)
        })
        guard case .permanentFailure = await rejected.image(for: uid("rejected")) else {
            Issue.record("An explicitly unavailable source must settle permanently")
            return
        }
    }

    @Test func cachedThumbnailSourceReusesOneDecodedImageAcrossSearchPasses() async throws {
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        let image = try #require(context.makeImage())
        let loads = ImageSourceLoadCounter()
        let source = CachedThumbnailMLImageSource(load: { _ in
            await loads.increment()
            return CoreMLSourceImage(cgImage: image)
        })

        guard case .image = await source.image(for: uid("shared")),
            case .image = await source.image(for: uid("shared"))
        else {
            Issue.record("The shared source must return the decoded image")
            return
        }
        #expect(await loads.value == 1)
    }

    @Test func cachedThumbnailSourceRevalidatesWarmAccessAndReleasesMemory() async throws {
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let authorized = DemandState(active: true)
        let loads = ImageSourceLoadCounter()
        let source = CachedThumbnailMLImageSource(
            lease: { _ -> (@Sendable () -> Bool)? in
                guard authorized.isActive() else { return nil }
                return { authorized.isActive() }
            },
            resolve: { _ in
                await loads.increment()
                return .image(CoreMLSourceImage(cgImage: image))
            })
        let photo = uid("leased")
        guard case .image = await source.image(for: photo) else {
            Issue.record("Authorized image must load")
            return
        }
        authorized.setActive(false)
        guard case .transientFailure = await source.image(for: photo) else {
            Issue.record("A warm ML cache must not bypass revoked analysis access")
            return
        }
        #expect(await loads.value == 1)
        authorized.setActive(true)
        _ = await source.image(for: photo)
        #expect(await loads.value == 2)
        await source.releaseMemory()
        _ = await source.image(for: photo)
        #expect(await loads.value == 3)
    }

    @Test func backgroundComputePolicyDoesNotChangeTheForegroundDefault() {
        #expect(CoreMLComputePolicy.default.resolved(requiresCPUOnly: true).computeUnits == .cpuOnly)
        #expect(CoreMLComputePolicy.default.resolved(requiresCPUOnly: false).computeUnits == .cpuAndNeuralEngine)
    }

    @Test func releasingMLImagesRejectsLateDecodeAndAllowsFreshRequests() async throws {
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let gate = ImageSourceDecodeGate()
        let source = CachedThumbnailMLImageSource(resolve: { _ in
            await gate.decode()
            return .image(CoreMLSourceImage(cgImage: image))
        })
        let photo = uid("decoding")
        let first = Task { await source.image(for: photo) }
        await gate.waitForStart()
        await source.releaseMemory()
        await gate.release()
        guard case .transientFailure = await first.value else {
            Issue.record("A decode from before memory release must be discarded")
            return
        }
        #expect(await gate.calls == 1)
        guard case .image = await source.image(for: photo) else {
            Issue.record("The next decode in the new epoch must work")
            return
        }
        #expect(await gate.calls == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"] != nil))
    func optionalRealTinyCLIPRuntimeSmoke() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_TINYCLIP_MODEL"])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 224,
                height: 224,
                bitsPerComponent: 8,
                bytesPerRow: 224 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        let image = try #require(context.makeImage())
        let descriptor = MLModelDescriptor(identifier: "tinyclip-39m", version: 1, embeddingDimension: 512)
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: FixedImageSource(image: CoreMLSourceImage(cgImage: image)),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )

        let imageOutcome = await encoder.embed(uid: uid("runtime"), descriptor: descriptor)
        guard case .embedded(let imageEmbedding) = imageOutcome else {
            Issue.record("Expected image embedding")
            return
        }
        let textEmbedding = try await encoder.encode(text: "a photo of trees", descriptor: descriptor)
        let secondImageOutcome = await encoder.embed(uid: uid("runtime-again"), descriptor: descriptor)
        #expect(imageEmbedding.count == 512)
        #expect(textEmbedding.count == 512)
        #expect(imageEmbedding.allSatisfy { $0.isFinite })
        #expect(textEmbedding.allSatisfy { $0.isFinite })
        guard case .embedded = secondImageOutcome else {
            Issue.record("Expected image model to reload after text inference")
            return
        }
    }

    @Test func encoderSchemaIsBuiltFromTheCatalogContract() {
        var contract = MLModelRuntimeContract.clipDualEncoder(imagePixelSide: 256)
        contract.imageFunctionName = "img_fn"
        contract.textFunctionName = "txt_fn"
        contract.imageInputName = "pixels"
        contract.tokenInputName = "tokens"
        contract.endTokenMaskInputName = "mask"
        contract.embeddingOutputName = "vec"
        contract.textContextLength = 64

        let schema = CoreMLDualEncoderSchema(contract: contract)
        #expect(schema.imageFunction == "img_fn")
        #expect(schema.textFunction == "txt_fn")
        #expect(schema.imageInput == "pixels")
        #expect(schema.tokenInput == "tokens")
        #expect(schema.endTokenMaskInput == "mask")
        #expect(schema.embeddingOutput == "vec")
        #expect(schema.contextLength == 64)
        #expect(schema.imagePixelSide == 256)
    }

    @Test func bundledTokenizerSatisfiesTheBuiltInContracts() throws {
        let tokenizer = try CLIPBPETokenizer.bundledTinyCLIP()
        #expect(tokenizer.contextLength == MLModelCatalogEntry.tinyCLIPVit40M.runtimeContract.textContextLength)
        #expect(MLModelCatalogEntry.tinyCLIPVit40M.runtimeContract.imagePixelSide == 224)
    }

    @Test func builtInCatalogEnforcesLicenseGates() {
        // TinyCLIP is MIT licensed, but upstream provides only PyTorch/safetensors artifacts.
        // Without a hosted Core ML artifact it has no download plan and cannot be selected.
        let tinyCLIP = MLModelCatalogEntry.tinyCLIPVit40M
        #expect(tinyCLIP.license.allowsRedistribution && tinyCLIP.license.allowsProductUse)
        #expect(tinyCLIP.downloadPlan == nil)
        #expect(!tinyCLIP.isDownloadable)

        // SigLIP2: Apache-2.0 (redistribution + product use), multilingual production entry;
        // no hosted CoreML artifact yet to no plan, not downloadable.
        let sigLIP2 = MLModelCatalogEntry.sigLIP2Base256
        #expect(sigLIP2.license.allowsRedistribution && sigLIP2.license.allowsProductUse)
        #expect(sigLIP2.downloadPlan == nil)
        #expect(!sigLIP2.isDownloadable)
        #expect(sigLIP2.runtimeContract.endTokenMaskInputName == nil)
        #expect(sigLIP2.runtimeContract.textContextLength == 64)
        #expect(sigLIP2.descriptor.embeddingDimension == 768)

        let releaseSelectable = MLModelCatalog.builtIn.selectableEntries(allowsDeveloperModels: false)
        #expect(releaseSelectable.isEmpty)
        #expect(Set(MLModelCatalog.builtIn.entries.map(\.id)) == Set([tinyCLIP.id, sigLIP2.id]))
    }

    @Test func defaultPolicyIsCpuAndNeuralEngine() {
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits == .cpuAndNeuralEngine)
    }

    @Test func policyProducesCorrectConfiguration() {
        let policy = CoreMLComputePolicy.default
        let config = policy.modelConfiguration
        #expect(config.computeUnits == .cpuAndNeuralEngine)
    }

    @Test func defaultInitAlsoMapsToCpuAndNeuralEngine() {
        let policy = CoreMLComputePolicy()
        #expect(policy.computeUnits == .cpuAndNeuralEngine)
        #expect(policy == .default)
    }

    @Test func policyEquality() {
        #expect(CoreMLComputePolicy.default == CoreMLComputePolicy())
    }

    @Test func noPublicProductionAPIExposesAllUnits() {
        // .all (GPU) must not be reachable as a production policy.
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits != .all)
    }

    @Test func noPublicProductionAPIExposesCpuOnly() {
        // .cpuOnly must not be reachable as a production policy.
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits != .cpuOnly)
    }

    @Test func vectorCipherRoundTripsAndBindsAccountAssetAndEpoch() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = CryptoKitMLVectorCipher(key: key, accountUID: "account-a")
        let context = MLVectorCipherContext(uid: uid("a0"), descriptor: descriptor)
        let plaintext = Data("private embedding".utf8)
        let ciphertext = try cipher.seal(plaintext, context: context)

        #expect(ciphertext != plaintext)
        #expect(try cipher.open(ciphertext, context: context) == plaintext)
        #expect(throws: (any Error).self) {
            _ = try cipher.open(
                ciphertext,
                context: MLVectorCipherContext(uid: uid("different"), descriptor: descriptor)
            )
        }
        let otherAccount = CryptoKitMLVectorCipher(key: key, accountUID: "account-b")
        #expect(throws: (any Error).self) {
            _ = try otherAccount.open(ciphertext, context: context)
        }
    }

    @Test func indexKeyDerivationIsStableAndAccountScoped() {
        let a1 = MLSearchKeyDerivation.localIndexKey(accountUID: "a", keyPassword: "secret")
        let a2 = MLSearchKeyDerivation.localIndexKey(accountUID: "a", keyPassword: "secret")
        let b = MLSearchKeyDerivation.localIndexKey(accountUID: "b", keyPassword: "secret")
        #expect(a1.withUnsafeBytes { Data($0) } == a2.withUnsafeBytes { Data($0) })
        #expect(a1.withUnsafeBytes { Data($0) } != b.withUnsafeBytes { Data($0) })
    }

    @Test func sqliteStoreRejectsWrongAccountCipher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-encrypted-store-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let correct = CryptoKitMLVectorCipher(key: key, accountUID: "account-a")
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: correct))
        store.upsert([
            MLEmbeddingRecord(uid: uid("a0"), descriptor: descriptor, vector: [1, 0, 0, 0])
        ])
        store.close()

        let wrong = CryptoKitMLVectorCipher(key: key, accountUID: "account-b")
        let wrongStore = try #require(SQLiteMLIndexStore(url: url, cipher: wrong))
        #expect(wrongStore.count(for: descriptor) == 1)
        #expect(wrongStore.allRecords(for: descriptor).isEmpty)
        #expect(wrongStore.vectorBlock(for: descriptor).isEmpty)
        #expect(wrongStore.count(for: descriptor) == 0)
        wrongStore.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: correct))
        #expect(reopened.allRecords(for: descriptor).isEmpty)
        reopened.close()
    }

    @Test(.timeLimit(.minutes(1))) func encryptedStoreTwentyThousandRowSmoke() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-encrypted-smoke-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        defer { try? FileManager.default.removeItem(at: root) }
        let cipher = CryptoKitMLVectorCipher(key: SymmetricKey(size: .bits256), accountUID: "smoke")
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { store.close() }
        let smokeDescriptor = MLModelDescriptor(identifier: "smoke", version: 1, embeddingDimension: 64)

        for batch in 0..<20 {
            let records = (0..<1_000).map { offset -> MLEmbeddingRecord in
                let index = batch * 1_000 + offset
                var vector = ContiguousArray<Float32>(repeating: 0, count: 64)
                vector[index % 64] = 1
                return MLEmbeddingRecord(
                    uid: PhotoUID(volumeID: "v", nodeID: String(format: "%06d", index)),
                    descriptor: smokeDescriptor,
                    vector: vector
                )
            }
            #expect(store.upsert(records).indexed == records.count)
        }

        #expect(store.vectorBlock(for: smokeDescriptor).count == 20_000)
    }

    @Test func accelerateScorerRanksCorrectly() {
        let block = block([
            ("a0", [1, 0, 0, 0]),
            ("a1", [0.5, 0.5, 0, 0]),
            ("a2", [0, 0, 0, 1]),
        ])
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 3)
        #expect(results.descriptor == descriptor)
        #expect(results.count == 3)
        #expect(results.results[0].uid == uid("a0"))
        #expect(results.results[0].score == 1.0)
        #expect(results.results[1].uid == uid("a1"))
        #expect(results.results[2].uid == uid("a2"))
        #expect(results.results[2].score == 0.0)
    }

    @Test func accelerateScorerMatchesReferenceImplementation() {
        // The Accelerate kernel must match the pure-Swift implementation within Float
        // tolerance, including result order.
        let block = block([
            ("a0", [0.9, 0.1, 0.2, 0.3]),
            ("a1", [0.1, 0.8, 0.4, 0.2]),
            ("a2", [0.2, 0.3, 0.5, 0.7]),
        ])
        let query = ContiguousArray<Float32>([0.5, 0.4, 0.3, 0.2])
        let accelResults = AccelerateVectorScorer().rank(block: block, query: query, limit: 3)
        let refResults = ReferenceDotProductScorer().rank(block: block, query: query, limit: 3)

        #expect(accelResults.results.map(\.uid.nodeID) == refResults.results.map(\.uid.nodeID))
        for (a, r) in zip(accelResults.results, refResults.results) {
            #expect(abs(a.score - r.score) < 1e-5)
        }
    }

    @Test func accelerateScorerDeterministicAcrossCalls() {
        let block = block([
            ("a0", [1, 0, 0, 0]),
            ("a1", [0.5, 0.5, 0, 0]),
        ])
        let q = ContiguousArray<Float32>([1, 0, 0, 0])
        let scorer = AccelerateVectorScorer()
        let r1 = scorer.rank(block: block, query: q, limit: 10)
        let r2 = scorer.rank(block: block, query: q, limit: 10)
        #expect(r1.results.map(\.uid.nodeID) == r2.results.map(\.uid.nodeID))
        #expect(r1.results.map(\.score) == r2.results.map(\.score))
    }

    @Test func accelerateScorerRespectsLimit() {
        let block = block((0..<5).map { ("a\($0)", [Float32($0), 0, 0, 0]) })
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 2)
        #expect(results.count == 2)
        #expect(results.results[0].uid == uid("a4"))
    }

    @Test func accelerateScorerQueryDimensionMismatchIsEmpty() {
        let block = block([("a0", [1, 0, 0, 0])])
        // Query of different dimension must not crash and must return no results.
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0, 0]), limit: 5)
        #expect(results.isEmpty)
    }

    @Test func accelerateScorerTieBreaksByRowOrderLikeReference() {
        let block = block([
            ("b-later", [1, 0, 0, 0]),
            ("a-earlier", [1, 0, 0, 0]),
        ])
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 2)
        // Shared ranking: equal scores break by row order (insertion order of the block).
        #expect(results.results.map(\.uid.nodeID) == ["b-later", "a-earlier"])
    }
}

private actor ImageSourceLoadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ImageSourceDecodeGate {
    private(set) var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false

    func decode() async {
        calls += 1
        started?.resume()
        started = nil
        guard !released else { return }
        await withCheckedContinuation { blocked = $0 }
    }

    func waitForStart() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }
}
