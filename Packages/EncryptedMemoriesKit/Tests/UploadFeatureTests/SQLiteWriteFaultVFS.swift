import SQLite3
import XCTest

/// A default VFS whose `xWrite` fails once with a chosen SQLite result code, so a test can produce BUSY, LOCKED,
/// NOMEM, INTERRUPT, IOERR and FULL without another connection. `xClose` restores the original methods. Shared by
/// the manifest-recovery test suites (#1004).
enum WriteFaultVFS {
    private nonisolated(unsafe) static var armedCode: Int32?
    private nonisolated(unsafe) static var base: UnsafeMutablePointer<sqlite3_vfs>?
    private nonisolated(unsafe) static var shim: UnsafeMutablePointer<sqlite3_vfs>?

    static func register() throws {
        guard shim == nil else { return }
        guard let system = sqlite3_vfs_find(nil) else { throw XCTSkip("SQLite has no default VFS") }
        base = system
        var vfs = system.pointee
        vfs.zName = UnsafePointer(strdup("write-fault-vfs"))
        vfs.pNext = nil
        vfs.xOpen = { _, name, file, flags, outFlags in
            guard let base = WriteFaultVFS.base, let file else { return SQLITE_ERROR }
            let result = base.pointee.xOpen(base, name, file, flags, outFlags)
            guard result == SQLITE_OK, let methods = file.pointee.pMethods else { return result }
            let table = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
            table.initialize(to: methods.pointee)
            table.pointee.xWrite = { file, buffer, count, offset in
                guard let file else { return SQLITE_IOERR }
                if let code = WriteFaultVFS.disarm() { return code }
                guard let original = WriteFaultVFS.wrappers[UnsafeMutableRawPointer(file)]?.original
                else { return SQLITE_IOERR }
                return original.pointee.xWrite!(file, buffer, count, offset)
            }
            table.pointee.xClose = { file in
                guard let file,
                    let wrapper = WriteFaultVFS.wrappers.removeValue(forKey: UnsafeMutableRawPointer(file)),
                    let close = wrapper.original.pointee.xClose
                else { return SQLITE_ERROR }
                // Point the file back at the default methods before freeing the wrapper table it names.
                file.pointee.pMethods = wrapper.original
                let result = close(file)
                wrapper.table.deinitialize(count: 1)
                wrapper.table.deallocate()
                return result
            }
            WriteFaultVFS.wrappers[UnsafeMutableRawPointer(file)] = (file: file, original: methods, table: table)
            file.pointee.pMethods = UnsafePointer(table)
            return result
        }
        let pointer = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        pointer.initialize(to: vfs)
        shim = pointer
        guard sqlite3_vfs_register(shim, 1) == SQLITE_OK else { throw XCTSkip("the VFS could not be registered") }
    }

    static func unregister() {
        guard let shim else { return }
        sqlite3_vfs_unregister(shim)
        // A store that this test left open still points at its wrapper table. Restore the default methods
        // before the tables are freed, so a later close never reads freed memory.
        for wrapper in wrappers.values {
            wrapper.file.pointee.pMethods = wrapper.original
            wrapper.table.deinitialize(count: 1)
            wrapper.table.deallocate()
        }
        wrappers.removeAll()
        armedCode = nil
        WriteFaultVFS.shim = nil
        base = nil
    }

    /// Arms a one-shot fault: the next intercepted write fails with `code`. Nil disarms without failing.
    static func arm(_ code: Int32?) {
        armedCode = code
    }

    private static func disarm() -> Int32? {
        let code = armedCode
        armedCode = nil
        return code
    }

    private nonisolated(unsafe) static var wrappers:
        [UnsafeMutableRawPointer: (
            file: UnsafeMutablePointer<sqlite3_file>, original: UnsafePointer<sqlite3_io_methods>,
            table: UnsafeMutablePointer<sqlite3_io_methods>
        )] = [:]
}
