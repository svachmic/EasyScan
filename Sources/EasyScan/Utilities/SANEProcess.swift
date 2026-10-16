// Runs the SANE `scanimage` command-line tool off the main actor.
//
// - stdout and stderr are drained asynchronously while the tool runs, so a chatty child can never block on a full
//   pipe (and we never deadlock waiting for it).
// - stderr is also scanned for `--progress` output ("Progress: 12.3%\r") and forwarded as 0...1 fractions.
// - A watchdog timeout and `terminate()` stop the tool gracefully: SIGTERM first (scanimage reacts by calling
//   sane_cancel, which parks the scan head and releases the USB device cleanly), then SIGKILL if it is still alive
//   after a grace period.
import Foundation

/// The outcome of one finished `scanimage` run.
struct SANEProcessResult {
    /// Exit status, or the signal number when `uncaughtSignal` is true. -1 if the tool was never launched.
    let exitCode: Int32
    let uncaughtSignal: Bool
    let stdout: Data
    let stderr: Data
    /// `terminate()` was called (by the user cancelling or by Swift task cancellation).
    let wasCancelled: Bool
    /// The watchdog timeout fired and the tool was stopped.
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !uncaughtSignal && !wasCancelled && !timedOut }
    /// Lossy UTF-8 decoding: invalid byte sequences become U+FFFD instead of failing.
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// One `scanimage` invocation. Create it, call `run()` once, and call `terminate()` from any thread to stop it.
final class SANEProcess: @unchecked Sendable {
    /// Seconds between the polite SIGTERM and the forced SIGKILL.
    static let killGracePeriod: TimeInterval = 5
    /// After the tool exits, how long to keep draining pipes that a stray grandchild might still hold open.
    static let pipeDrainGracePeriod: TimeInterval = 2
    /// Upper bound for the stderr we keep around for error messages (progress output alone can be ~50 KB).
    private static let maxStderrBytes = 1 << 20

    let executableURL: URL
    let arguments: [String]
    private let timeout: TimeInterval?
    private let onProgress: (@Sendable (Double) -> Void)?

    // All mutable state below is guarded by `lock`.
    private let lock = NSLock()
    private let process = Process()
    private var launched = false
    private var exited = false
    private var signalled = false
    private var cancelRequested = false
    private var timedOut = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var finished = false
    private var continuation: CheckedContinuation<SANEProcessResult, Error>?
    private var stdoutData = Data()
    private var stderrData = Data()
    /// Unterminated tail of stderr, kept until the next "\r" or "\n" arrives so progress lines are parsed whole.
    private var pendingStderrLine = Data()

    init(executableURL: URL, arguments: [String], timeout: TimeInterval?,
         onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.onProgress = onProgress
    }

    /// The command line, for logging.
    var commandLine: String { ([executableURL.path] + arguments).joined(separator: " ") }

    /// Launches the tool and waits until it has exited and both pipes are drained. Throws only if the tool could not
    /// be launched at all; every other outcome (non-zero exit, cancellation, timeout) is described by the result.
    func run() async throws -> SANEProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SANEProcessResult, Error>) in
                launch(continuation)
            }
        } onCancel: {
            terminate()
        }
    }

    /// Stops the tool (SIGTERM, then SIGKILL after `killGracePeriod`). Safe to call from any thread, at any time,
    /// any number of times; if the tool has not been launched yet, it never will be.
    func terminate() { stop(timedOut: false) }

    // MARK: - Private

    private func launch(_ continuation: CheckedContinuation<SANEProcessResult, Error>) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // English messages (we parse them) and "." as the decimal separator for -l/-t/-x/-y values.
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // The run is complete once the process has exited AND both pipes have reached end-of-file (or, should
        // something else keep a pipe open, `pipeDrainGracePeriod` after the exit).
        process.terminationHandler = { [self] _ in
            lock.lock()
            exited = true
            lock.unlock()
            finishIfDone(force: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeDrainGracePeriod) { [self] in
                finishIfDone(force: true)
            }
        }

        // Launch under the lock so a concurrent terminate() either prevents the launch or sees `launched == true`.
        lock.lock()
        if cancelRequested {
            lock.unlock()
            process.terminationHandler = nil
            continuation.resume(returning: SANEProcessResult(exitCode: -1, uncaughtSignal: false, stdout: Data(),
                                                             stderr: Data(), wasCancelled: true, timedOut: false))
            return
        }
        do {
            try process.run()
            launched = true
            self.continuation = continuation
            lock.unlock()
        } catch {
            lock.unlock()
            process.terminationHandler = nil
            continuation.resume(throwing: ScanError("Could not start scanimage: \(error.localizedDescription)"))
            return
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lock.lock()
                stdoutClosed = true
                lock.unlock()
                finishIfDone(force: false)
            } else {
                lock.lock()
                stdoutData.append(chunk)
                lock.unlock()
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lock.lock()
                stderrClosed = true
                lock.unlock()
                finishIfDone(force: false)
            } else {
                appendStderr(chunk)
            }
        }

        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.stop(timedOut: true)
            }
        }
    }

    /// Resumes the caller exactly once, when the process has exited and the pipes are drained (or `force`).
    private func finishIfDone(force: Bool) {
        lock.lock()
        guard !finished, exited, force || (stdoutClosed && stderrClosed), let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let result = SANEProcessResult(exitCode: process.terminationStatus,
                                       uncaughtSignal: process.terminationReason == .uncaughtSignal,
                                       stdout: stdoutData, stderr: stderrData,
                                       wasCancelled: cancelRequested, timedOut: timedOut)
        lock.unlock()
        if let handle = (process.standardOutput as? Pipe)?.fileHandleForReading { handle.readabilityHandler = nil }
        if let handle = (process.standardError as? Pipe)?.fileHandleForReading { handle.readabilityHandler = nil }
        process.terminationHandler = nil
        continuation.resume(returning: result)
    }

    private func appendStderr(_ chunk: Data) {
        var fractions: [Double] = []
        lock.lock()
        stderrData.append(chunk)
        if stderrData.count > Self.maxStderrBytes {
            stderrData = Data(stderrData.suffix(Self.maxStderrBytes / 2))
        }
        if onProgress != nil {
            pendingStderrLine.append(chunk)
            let isSeparator: (UInt8) -> Bool = { $0 == 0x0A || $0 == 0x0D } // "\n" or "\r"
            if let lastSeparator = pendingStderrLine.lastIndex(where: isSeparator) {
                let complete = pendingStderrLine[pendingStderrLine.startIndex..<lastSeparator]
                for line in complete.split(whereSeparator: isSeparator) {
                    if let fraction = SANEParsing.progressFraction(fromLine: String(decoding: line, as: UTF8.self)) {
                        fractions.append(fraction)
                    }
                }
                pendingStderrLine = Data(pendingStderrLine[pendingStderrLine.index(after: lastSeparator)...])
            }
            if pendingStderrLine.count > 4096 { pendingStderrLine.removeAll() } // not progress output; don't grow
        }
        lock.unlock()
        // Only the newest value matters; report it outside the lock.
        if let latest = fractions.last { onProgress?(latest) }
    }

    private func stop(timedOut becauseOfTimeout: Bool) {
        lock.lock()
        if exited { lock.unlock(); return }
        if becauseOfTimeout { timedOut = true } else { cancelRequested = true }
        // Signal only once: a second SIGTERM makes scanimage _exit() immediately, skipping its sane_cancel cleanup.
        let shouldSignal = launched && !signalled
        if shouldSignal { signalled = true }
        let pid = process.processIdentifier
        lock.unlock()
        guard shouldSignal, pid > 0 else { return }

        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = !self.exited
            self.lock.unlock()
            if stillRunning { kill(pid, SIGKILL) }
        }
    }
}
