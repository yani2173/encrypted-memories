import Foundation

/// The background log kept on the device for the support file: each milestone line with its time, in one file of at
/// most `limit` bytes. A write that passes the limit drops the oldest lines down to `trimTarget`, so the file holds the
/// last nights. It stores only `BackgroundWorkLog` lines, which hold fixed words, names, flags, counts and durations.
/// The sign-out purge deletes its directory; while a purge is pending it writes nothing, so it cannot bring the file back.
public final class BackgroundWorkLogFile: @unchecked Sendable {
    public static let defaultFileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("EncryptedMemories/background-log-v1.txt", isDirectory: false)
    /// The app's file. A process that is no app, such as the package test runner, keeps no file.
    public static let shared = BackgroundWorkLogFile(
        fileURL: Bundle.main.bundleURL.pathExtension == "app" ? defaultFileURL : nil)
    public static let limit = 1_000_000
    public static let trimTarget = 768_000
    /// No file protection, as the background-window ledger: the windows right after a restart run before the first unlock.
    static let fileWriteOptions: Data.WritingOptions = [.atomic, .noFileProtection]

    /// The stored lines, oldest first, and how many older lines the bound dropped.
    public struct Export: Sendable, Equatable {
        public let lines: [String]
        public let droppedLines: Int
    }

    private static let droppedPrefix = "# dropped "
    let fileURL: URL?
    private let limit: Int
    private let trimTarget: Int
    private let isPurgePending: @Sendable () -> Bool
    /// One queue for every write and read, so the lines keep their order and the caller never waits for the disk.
    private let queue = DispatchQueue(label: "at.oncloud.encryptedmemories.background-log")
    private let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(
        fileURL: URL?, limit: Int = BackgroundWorkLogFile.limit, trimTarget: Int = BackgroundWorkLogFile.trimTarget,
        isPurgePending: @escaping @Sendable () -> Bool = { BackupLocalDataPurge.isPurgePending() }
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.trimTarget = min(trimTarget, limit)
        self.isPurgePending = isPurgePending
    }

    /// Appends one line with its time, after the lines that came before. Only `BackgroundWorkLog` writes, so only its
    /// lines reach the file.
    func append(_ line: String, at date: Date = Date()) {
        guard let fileURL else { return }
        queue.async { [self] in
            guard !isPurgePending() else { return }
            let text = timestamp.string(from: date) + " " + line + "\n"
            write(Data(text.utf8), to: fileURL)
        }
    }

    /// The stored lines, after every line that was appended before this call.
    public func export() -> Export {
        queue.sync {
            guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return Export(lines: [], droppedLines: 0)
            }
            var dropped = 0
            var lines: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(Self.droppedPrefix) {
                    dropped = Int(line.dropFirst(Self.droppedPrefix.count)) ?? 0
                } else {
                    lines.append(String(line))
                }
            }
            return Export(lines: lines, droppedLines: dropped)
        }
    }

    private func write(_ data: Data, to fileURL: URL) {
        let manager = FileManager.default
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: data)) != nil else { return }
        } else {
            // An existing file that does not open now keeps its lines; only a missing file is created.
            guard !manager.fileExists(atPath: fileURL.path) else { return }
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: fileURL, options: Self.fileWriteOptions)) != nil else { return }
        }
        let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > limit { trim(fileURL) }
    }

    /// Drops the oldest lines until the file fits `trimTarget`, and counts them in its first line.
    private func trim(_ fileURL: URL) {
        let manager = FileManager.default
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            // An unreadable file cannot be shortened; it goes, so the bound holds.
            try? manager.removeItem(at: fileURL)
            return
        }
        var dropped = 0
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let first = lines.first, first.hasPrefix(Self.droppedPrefix) {
            dropped = Int(first.dropFirst(Self.droppedPrefix.count)) ?? 0
            lines.removeFirst()
        }
        var size = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var start = 0
        while start < lines.count, size > trimTarget {
            size -= lines[start].utf8.count + 1
            start += 1
        }
        dropped += start
        let kept = [Self.droppedPrefix + String(dropped)] + lines[start...]
        guard
            (try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: Self.fileWriteOptions))
                != nil
        else {
            // Without room for the shorter copy, the bound still holds: every line goes, and the count stays.
            try? manager.removeItem(at: fileURL)
            try? Data((Self.droppedPrefix + String(dropped + lines.count - start) + "\n").utf8)
                .write(to: fileURL, options: [.noFileProtection])
            return
        }
    }
}
