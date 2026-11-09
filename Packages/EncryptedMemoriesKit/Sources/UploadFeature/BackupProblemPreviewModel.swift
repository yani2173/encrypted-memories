import CoreGraphics
import Foundation
import PhotosCore
import UploadCore

/// One open problem list owns these small local previews. This RAM cache is separate from Proton's
/// encrypted thumbnail cache: it never reads remote media or writes a disk copy.
@MainActor
public final class BackupProblemPreviewModel {
    public typealias Loader = @Sendable (PhotoUID) async -> CGImage?

    public static var defaultCostLimit: Int {
        #if os(macOS)
            32 * 1024 * 1024
        #else
            8 * 1024 * 1024
        #endif
    }

    private final class Request {
        let token = UUID()
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var task: Task<Void, Never>?
    }

    private let load: Loader
    private let costLimit: Int
    private let governor: MemoryPressureGovernor
    private var registration: MemoryPressureRegistration?
    private var isOpen = false
    private var canCache = true
    private var images: [PhotoUID: CGImage] = [:]
    private var order: [PhotoUID] = []
    private var byteCost = 0
    private var requests: [PhotoUID: Request] = [:]
    private var queued: [PhotoUID] = []
    private static let maxConcurrentRequests = 4

    public init(
        costLimit: Int = BackupProblemPreviewModel.defaultCostLimit,
        memoryGovernor: MemoryPressureGovernor = .shared,
        load: @escaping Loader
    ) {
        self.costLimit = max(0, costLimit)
        self.governor = memoryGovernor
        self.load = load
    }

    deinit {
        let registration = registration
        Task { @MainActor in registration?.end() }
    }

    /// All resources of a Photos asset use the same local identifier. Folder files have no Photos preview.
    public static func uid(for source: UploadSourceIdentity?) -> PhotoUID? {
        guard let source, source.kind == .photoLibraryAsset, !source.identifier.isEmpty else { return nil }
        return PhotoUID(localPending: .photoLibrary, identifier: source.identifier)
    }

    public func open() {
        guard !isOpen else { return }
        isOpen = true
        registration = governor.register { [weak self] tier in
            guard let self else { return }
            canCache = tier == .normal
            if !canCache { release() }
        }
    }

    public func close() {
        isOpen = false
        registration?.end()
        registration = nil
        release()
    }

    public func thumbnail(for uid: PhotoUID) async -> CGImage? {
        guard isOpen, !Task.isCancelled else { return nil }
        if let image = cachedImage(for: uid) { return image }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isOpen, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let request: Request
                if let existing = requests[uid] {
                    request = existing
                } else {
                    request = Request()
                    requests[uid] = request
                    queued.append(uid)
                }
                request.waiters[waiter] = continuation
                startQueuedRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter, for: uid) }
        }
    }

    var pendingWaiterCount: Int { requests.values.reduce(0) { $0 + $1.waiters.count } }

    func cachedImage(for uid: PhotoUID) -> CGImage? {
        guard let image = images[uid] else { return nil }
        order.removeAll { $0 == uid }
        order.append(uid)
        return image
    }

    private func startQueuedRequests() {
        while isOpen, requests.values.filter({ $0.task != nil }).count < Self.maxConcurrentRequests,
            !queued.isEmpty
        {
            let uid = queued.removeFirst()
            guard let request = requests[uid] else { continue }
            let token = request.token
            request.task = Task { [load, weak self] in
                let image = await load(uid)
                self?.finish(uid, token: token, image: image)
            }
        }
    }

    private func finish(_ uid: PhotoUID, token: UUID, image: CGImage?) {
        guard let request = requests[uid], request.token == token else { return }
        requests[uid] = nil
        if let image, isOpen, canCache { store(image, for: uid) }
        for waiter in request.waiters.values { waiter.resume(returning: image) }
        startQueuedRequests()
    }

    private func cancel(_ waiter: UUID, for uid: PhotoUID) {
        guard let request = requests[uid] else { return }
        request.waiters.removeValue(forKey: waiter)?.resume(returning: nil)
        guard request.waiters.isEmpty else { return }
        requests[uid] = nil
        queued.removeAll { $0 == uid }
        request.task?.cancel()
        startQueuedRequests()
    }

    private func store(_ image: CGImage, for uid: PhotoUID) {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost <= costLimit else { return }
        while byteCost > costLimit - cost, let oldest = order.first {
            order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { byteCost -= removed.bytesPerRow * removed.height }
        }
        images[uid] = image
        order.append(uid)
        byteCost += cost
    }

    private func release() {
        images.removeAll()
        order.removeAll()
        byteCost = 0
        let retired = requests.values
        requests.removeAll()
        queued.removeAll()
        for request in retired {
            request.task?.cancel()
            for waiter in request.waiters.values { waiter.resume(returning: nil) }
        }
    }
}
