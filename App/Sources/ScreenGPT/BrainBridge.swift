//
//  BrainBridge.swift
//  ScreenGPT
//
//  Manages the lifecycle of the Python "brain" helper subprocess and
//  speaks the JSON-over-stdio protocol with it. See ../Brain/README.md
//  for the protocol spec.
//
//  Threading model:
//    • `start()` is called once from the main actor.
//    • A background queue reads stdout in chunks, splits on '\n', parses
//      each line as JSON, decodes it into a `BrainEvent`, and yields it
//      to the `events` AsyncStream.
//    • Consumers iterate `for await event in bridge.events`.
//    • `send(_:)` writes to stdin from any thread — Foundation's FileHandle
//      writes are atomic for small chunks (<PIPE_BUF, i.e. 4–64 KB).
//

import Foundation

enum BrainBridgeError: Error, LocalizedError {
    case helperNotFound(searched: [String])
    case alreadyStarted

    var errorDescription: String? {
        switch self {
        case .helperNotFound(let paths):
            return "Brain helper not found. Searched:\n" + paths.joined(separator: "\n")
        case .alreadyStarted:
            return "BrainBridge.start() called twice."
        }
    }
}

final class BrainBridge {

    // ── Process plumbing ────────────────────────────────────────────────────
    private let process = Process()
    private let stdinPipe  = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// Path of the helper binary that was launched. Set by `start()`.
    private(set) var helperPath: URL?

    // ── Public event stream ─────────────────────────────────────────────────
    /// Async stream of decoded events from the brain. Consume on any actor:
    ///
    ///     Task {
    ///         for await event in bridge.events { ... }
    ///     }
    ///
    /// The stream finishes when the brain process exits.
    let events: AsyncStream<BrainEvent>
    private let continuation: AsyncStream<BrainEvent>.Continuation

    // ── stdout line buffering ───────────────────────────────────────────────
    private var stdoutBuffer = Data()
    private let bufferLock = NSLock()

    // ── Init ────────────────────────────────────────────────────────────────
    init() {
        var localContinuation: AsyncStream<BrainEvent>.Continuation!
        events = AsyncStream(BrainEvent.self, bufferingPolicy: .unbounded) { cont in
            localContinuation = cont
        }
        continuation = localContinuation
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    func start() throws {
        guard !process.isRunning else { throw BrainBridgeError.alreadyStarted }

        let helper = try Self.locateHelper()
        helperPath = helper

        process.executableURL = helper
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // Read stdout chunks asynchronously. Foundation's readabilityHandler
        // fires on a background queue managed by libdispatch — we just need
        // to be threadsafe about buffer mutation.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — brain exited
                self?.finish()
                return
            }
            self?.consumeStdoutChunk(chunk)
        }

        // Mirror stderr to our own stderr for debugging; the brain uses
        // stderr for free-form logs and structured `log` events appear on
        // stdout, so this is purely a debugging aid.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                FileHandle.standardError.write(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        try process.run()
    }

    /// Send `{"cmd":"shutdown"}` and wait briefly for the brain to exit.
    func shutdown() {
        send(["cmd": "shutdown"])
        // Don't block the main thread — the terminationHandler closes the
        // stream once the process exits.
    }

    // ── Send ────────────────────────────────────────────────────────────────

    /// Serialise `command` as JSON and write a single line to the brain's stdin.
    /// Returns immediately; never blocks.
    func send(_ command: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: command,
                                                   options: [.fragmentsAllowed])
            data.append(0x0A)  // '\n' — line delimiter
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("[BrainBridge] send failed: \(error)\n".utf8))
        }
    }

    // ── stdout consumption ──────────────────────────────────────────────────

    private func consumeStdoutChunk(_ chunk: Data) {
        bufferLock.lock()
        stdoutBuffer.append(chunk)

        // Split on newlines, yield each complete line as an event.
        while let nlIdx = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: nlIdx)
            // Remove the line and the trailing newline byte.
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nlIdx)
            // Drop the lock around event parsing/yielding so a slow consumer
            // doesn't block I/O.
            bufferLock.unlock()
            if let event = decode(lineData) {
                continuation.yield(event)
            }
            bufferLock.lock()
        }
        bufferLock.unlock()
    }

    private func decode(_ line: Data) -> BrainEvent? {
        guard !line.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any] else {
            FileHandle.standardError.write(Data("[BrainBridge] bad JSON line: \(line.count)b\n".utf8))
            return nil
        }
        return BrainEvent.decode(json)
    }

    private var didFinish = false
    private let finishLock = NSLock()

    private func finish() {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        continuation.finish()
    }

    // ── Helper-binary discovery ─────────────────────────────────────────────

    /// Locate the Nuitka-compiled brain helper.
    ///
    /// Search order:
    ///   1. `$CALIB_HELPER_PATH` — explicit override for development.
    ///   2. `Bundle.main/Contents/Resources/brain/helper` — production layout
    ///      inside the .app bundle.
    ///   3. `<executable_dir>/helper` — when running raw `swift run` after
    ///      a `cp Brain/build/helper App/.build/debug/`.
    ///   4. `<package_root>/../Brain/build/helper` — for `swift run` inside
    ///      the SPM checkout without copying first.
    static func locateHelper() throws -> URL {
        var searched: [String] = []

        if let envPath = ProcessInfo.processInfo.environment["CALIB_HELPER_PATH"] {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            searched.append("$CALIB_HELPER_PATH=\(envPath)")
        }

        if let bundleURL = Bundle.main.url(
            forResource: "helper", withExtension: nil, subdirectory: "brain"
        ) {
            return bundleURL
        }
        searched.append("\(Bundle.main.bundlePath)/Contents/Resources/brain/helper")

        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let alongside = exeDir.appendingPathComponent("helper")
        if FileManager.default.isExecutableFile(atPath: alongside.path) {
            return alongside
        }
        searched.append(alongside.path)

        let devPath = exeDir
            .deletingLastPathComponent()       // .build/
            .deletingLastPathComponent()       // App/
            .appendingPathComponent("Brain/build/helper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        searched.append(devPath.path)

        throw BrainBridgeError.helperNotFound(searched: searched)
    }
}
