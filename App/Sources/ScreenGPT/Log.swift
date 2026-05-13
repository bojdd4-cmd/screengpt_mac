//
//  Log.swift
//  ScreenGPT
//
//  Append-only file log + stderr mirror.  We need both because:
//   • During an LDB exam the terminal is often hidden behind LDB, so
//     stderr output isn't visible until after the user quits LDB.
//   • A persistent file at ~/Library/Logs/ScreenGPT/screengpt.log lets the
//     user (or support) inspect what happened after the session ends.
//
//  Single shared FileHandle, opened once and held for the app's lifetime.
//  Writes are line-formatted and lock-protected; safe to call from any
//  thread.
//

import Foundation

enum Log {

    private static let lock = NSLock()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Path of the active logfile.  `nil` if creation failed (e.g.
    /// read-only filesystem).
    static let fileURL: URL? = {
        guard let libDir = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = libDir.appendingPathComponent("Logs/Color Calibration", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data(
                "[Log] could not create log dir: \(error)\n".utf8))
            return nil
        }
        return dir.appendingPathComponent("calibration.log")
    }()

    static let fileHandle: FileHandle? = {
        guard let url = fileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fh = try? FileHandle(forWritingTo: url)
        try? fh?.seekToEnd()
        return fh
    }()

    /// Async-signal-safe file descriptor for the logfile. Used by signal
    /// handlers via `write(2)`. Returns -1 if the file couldn't be opened.
    static var fileDescriptor: Int32 {
        fileHandle?.fileDescriptor ?? -1
    }

    /// Write a single line to both stderr and the logfile.  Thread-safe.
    static func write(_ message: String) {
        let line = "[\(isoFormatter.string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        lock.lock()
        FileHandle.standardError.write(data)
        if let fh = fileHandle {
            try? fh.write(contentsOf: data)
        }
        lock.unlock()
    }
}
