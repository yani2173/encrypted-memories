import Foundation
import PhotosCore

/// Bounded, crash-safe temp storage for exported backup resources (PhotoKit originals are
/// materialized here before hashing/upload). Platform-neutral Foundation only.
///
/// Safety model:
/// - files are written under a `.partial` name and only renamed on `commit`, so a crash can
///   never leave a half-written file that looks complete,
/// - `sweep()` (call at controller start, when no run is active) deletes everything - every
///   temp file is re-derivable from the library, so the sweep can be total,
/// - reservations and streamed writes enforce the disk budget. `maximumBytes` bounds the normal
///   staging pool, not the size of one camera asset: one known oversized resource may temporarily
///   exceed it when the volume has enough free space. This keeps large videos uploadable without
///   allowing several large exports to fill the device in parallel.
public final class BackupTempFileStore: @unchecked Sendable {
    public enum BackupTempFileError: Error, Equatable, LocalizedError {
        case diskBudgetExceeded
        /// The device needs about `requiredBytes` of free space for this file, for example a large video that must
        /// be downloaded from iCloud and copied for its upload.
        case needsFreeSpace(requiredBytes: Int64)

        public var errorDescription: String? {
            switch self {
            case .diskBudgetExceeded:
                return L10n.string("backup.error_low_space")
            case .needsFreeSpace(let requiredBytes):
                return L10n.string("backup.error_needs_free_space \(L10n.fileSize(requiredBytes))")
            }
        }
    }

    public let directory: URL
    /// Cap for normal concurrent staging. One known larger resource may exceed it exclusively.
    public let maximumBytes: Int64
    /// Free space the volume must retain beyond the file being written.
    public let minimumFreeBytes: Int64

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let now: @Sendable () -> Date
    private struct Reservation {
        var expectedBytes: Int64
        var writtenBytes: Int64
        let isOversized: Bool
        /// Bytes staged ahead of the duplicate check. All staged files together use at most half of the normal
        /// pool, so exports of photos selected for upload always keep the other half. An iCloud original whose known
        /// size exceeds that half is not staged this way: it reserves its exact size like its export would.
        var isStaged = false
    }
    private var reservations: [URL: Reservation] = [:]
    private struct CapacitySample {
        var availableBytes: Int64
        var sampledAt: Date
        var accountedWrites: Int64
    }
    private var capacitySample: CapacitySample?
    private static let capacityResampleBytes: Int64 = 16 << 20
    private static let capacityResampleInterval: TimeInterval = 0.5

    public convenience init(
        directory: URL,
        maximumBytes: Int64 = DiskCacheBudgetPolicy(platform: .mobile).backupMaximumBytes,
        minimumFreeBytes: Int64 = DiskCacheBudgetPolicy(platform: .mobile).backupMinimumFreeBytes
    ) {
        self.init(
            directory: directory,
            maximumBytes: maximumBytes,
            minimumFreeBytes: minimumFreeBytes,
            availableCapacity: DeviceStorage.availableCapacity(at:),
            now: { Date() }
        )
    }

    convenience init(
        directory: URL,
        policyBudget: @Sendable (DiskCacheBudgetPolicy) -> (Int64, Int64),
        availableCapacity: @Sendable @escaping (URL) -> Int64?,
        now: @Sendable @escaping () -> Date
    ) {
        let (maximumBytes, minimumFreeBytes) = policyBudget(DiskCacheBudgetPolicy(platform: .mobile))
        self.init(
            directory: directory,
            maximumBytes: maximumBytes,
            minimumFreeBytes: minimumFreeBytes,
            availableCapacity: availableCapacity,
            now: now
        )
    }

    init(
        directory: URL,
        maximumBytes: Int64,
        minimumFreeBytes: Int64,
        availableCapacity: @Sendable @escaping (URL) -> Int64?,
        now: @Sendable @escaping () -> Date
    ) {
        self.directory = directory
        self.maximumBytes = max(1, maximumBytes)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.availableCapacity = availableCapacity
        self.now = now
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes every temp file (partial or committed). Call only while no run is active - all
    /// contents are re-derivable exports.
    public func sweep() {
        lock.withLock {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { return }
            for url in entries { try? fileManager.removeItem(at: url) }
            reservations.removeAll(keepingCapacity: true)
            capacitySample = nil
        }
    }

    /// Reserves a unique `.partial` destination for an export of roughly `expectedBytes`.
    /// The caller streams into the returned URL, then calls `commit` (or `discard`). A `staging` reservation holds
    /// bytes read before the duplicate check; `recordWrite` refuses a chunk once all staged files together would
    /// exceed half of `maximumBytes`.
    public func reserve(filename: String, expectedBytes: Int64, staging: Bool = false) throws -> URL {
        try lock.withLock {
            let expected = max(0, expectedBytes)
            let isOversized = expected > maximumBytes
            let hasOversizedReservation = reservations.values.contains(where: \.isOversized)

            if isOversized {
                guard !hasOversizedReservation else {
                    throw BackupTempFileError.diskBudgetExceeded
                }
            } else {
                // Once a large camera asset owns the overflow slot, do not stage more files beside
                // it. Reservations that were already active may finish normally.
                guard !hasOversizedReservation,
                    addingClamped(normalAllocationLocked(), expected) <= maximumBytes
                else {
                    throw BackupTempFileError.diskBudgetExceeded
                }
            }

            let futureWrites = addingClamped(expected, reservedUnwrittenBytesLocked())
            let requiredFree = addingClamped(minimumFreeBytes, futureWrites)
            if let free = sampledFreeBytesLocked(forceRefresh: true), free < requiredFree {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let safeName = filename.replacingOccurrences(of: "/", with: "_")
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName).partial")
            reservations[url] = Reservation(
                expectedBytes: expected,
                writtenBytes: 0,
                isOversized: isOversized,
                isStaged: staging
            )
            return url
        }
    }

    /// Whether the volume has room for `bytes` more on top of the reserved free space and the unwritten reservations.
    public func hasFreeSpace(forAdditionalBytes bytes: Int64) -> Bool {
        (try? ensureFreeSpace(forAdditionalBytes: bytes)) != nil
    }

    /// Throws `needsFreeSpace` unless the volume has room for `bytes` more on top of the reserved free space. Callers
    /// check before a large copy for upload, so a file that cannot fit fails at once with the space it needs.
    public func ensureFreeSpace(forAdditionalBytes bytes: Int64) throws {
        try lock.withLock {
            let required = addingClamped(minimumFreeBytes, addingClamped(max(0, bytes), reservedUnwrittenBytesLocked()))
            if let free = sampledFreeBytesLocked(forceRefresh: true), free < required {
                throw BackupTempFileError.needsFreeSpace(requiredBytes: required)
            }
        }
    }

    /// Accounts a source chunk before it reaches disk. This is the public-API-safe budget path for
    /// PhotoKit, whose resource length is not exposed by a supported API.
    public func recordWrite(to url: URL, byteCount: Int) throws {
        guard byteCount > 0 else { return }
        try lock.withLock {
            guard var reservation = reservations[url] else {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let increment = Int64(byteCount)
            let previousAllocation = max(reservation.expectedBytes, reservation.writtenBytes)
            let (nextWritten, sumOverflowed) = reservation.writtenBytes.addingReportingOverflow(increment)
            guard !sumOverflowed else {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let nextAllocation = max(reservation.expectedBytes, nextWritten)
            if reservation.isOversized {
                // The identity pass supplied an exact size. If PhotoKit now produces more bytes,
                // the asset changed and the runner must re-resolve it rather than grow without bound.
                guard reservation.expectedBytes > 0, nextWritten <= reservation.expectedBytes else {
                    throw BackupTempFileError.diskBudgetExceeded
                }
            } else {
                // All files created by this store have reservations. Avoid enumerating the temp
                // directory for every PhotoKit chunk; the filesystem scan belongs on reserve only.
                let normalAllocation = addingClamped(
                    normalReservedBytesLocked() - previousAllocation,
                    nextAllocation
                )
                guard normalAllocation <= maximumBytes else {
                    throw BackupTempFileError.diskBudgetExceeded
                }
                if reservation.isStaged {
                    let stagedAllocation =
                        stagedBytesLocked() - reservation.writtenBytes + nextWritten
                    guard stagedAllocation <= maximumBytes / 2 else {
                        throw BackupTempFileError.diskBudgetExceeded
                    }
                }
            }

            reservation.writtenBytes = nextWritten
            let futureWrites = reservedUnwrittenBytesLocked(replacing: url, with: reservation)
            let requiredFree = addingClamped(
                minimumFreeBytes,
                addingClamped(increment, futureWrites)
            )
            if let free = sampledFreeBytesLocked(forceRefresh: false), free < requiredFree {
                throw BackupTempFileError.diskBudgetExceeded
            }
            reservations[url] = reservation
            if capacitySample != nil { capacitySample!.accountedWrites += increment }
        }
    }

    /// Promotes a fully-written `.partial` file to its final name and returns the final URL.
    public func commit(_ partialURL: URL) throws -> URL {
        try lock.withLock {
            let finalURL = URL(fileURLWithPath: String(partialURL.path.dropLast(".partial".count)))
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: partialURL, to: finalURL)
            if let reservation = reservations.removeValue(forKey: partialURL) {
                reservations[finalURL] = reservation
            }
            return finalURL
        }
    }

    public func discard(_ url: URL) {
        lock.withLock {
            reservations.removeValue(forKey: url)
            try? fileManager.removeItem(at: url)
        }
    }

    public func usedBytes() -> Int64 {
        lock.withLock { usedBytesLocked() }
    }

    private func usedBytesLocked() -> Int64 {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )
        else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func normalAllocationLocked() -> Int64 {
        let reserved = normalReservedBytesLocked()
        let trackedWrites = reservations.values.reduce(into: Int64(0)) { total, reservation in
            total = addingClamped(total, reservation.writtenBytes)
        }
        let untrackedBytes = max(0, usedBytesLocked() - trackedWrites)
        return addingClamped(reserved, untrackedBytes)
    }

    private func stagedBytesLocked() -> Int64 {
        reservations.values.reduce(into: Int64(0)) { total, reservation in
            guard reservation.isStaged else { return }
            total = addingClamped(total, reservation.writtenBytes)
        }
    }

    private func normalReservedBytesLocked() -> Int64 {
        reservations.values.reduce(into: Int64(0)) { total, reservation in
            guard !reservation.isOversized else { return }
            total = addingClamped(total, max(reservation.expectedBytes, reservation.writtenBytes))
        }
    }

    private func reservedUnwrittenBytesLocked(
        replacing url: URL? = nil,
        with replacement: Reservation? = nil
    ) -> Int64 {
        reservations.reduce(into: Int64(0)) { total, element in
            let reservation = element.key == url ? (replacement ?? element.value) : element.value
            let remaining = max(0, reservation.expectedBytes - reservation.writtenBytes)
            total = addingClamped(total, remaining)
        }
    }

    private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private func sampledFreeBytesLocked(forceRefresh: Bool) -> Int64? {
        let currentTime = now()
        let shouldRefresh =
            forceRefresh
            || capacitySample == nil
            || capacitySample!.accountedWrites >= Self.capacityResampleBytes
            || currentTime.timeIntervalSince(capacitySample!.sampledAt) >= Self.capacityResampleInterval
        if shouldRefresh {
            guard let fresh = availableCapacity(directory) else {
                capacitySample = nil
                return nil
            }
            capacitySample = CapacitySample(availableBytes: fresh, sampledAt: currentTime, accountedWrites: 0)
        }
        guard let capacitySample else { return nil }
        return max(0, capacitySample.availableBytes - capacitySample.accountedWrites)
    }
}
