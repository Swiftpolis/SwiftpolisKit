import Foundation
import Synchronization

#if os(macOS)
/// Runs one of the bundled programs and hands over its output.
///
/// Stopping asks politely first, because yt-dlp tidies up after an interrupt and leaves a partial
/// file it can resume. It's made to go if it doesn't.
public final class HelperProcess: Sendable {
    public struct Ending: Sendable {
        public let exitCode: Int32
        /// Standard output, if it was asked for. Otherwise it went to `onLine`.
        public let output: Data
        public let errorText: String
    }

    private struct State {
        var hasStarted = false
        var isStopRequested = false
        var outputBuffer = Data()
        var outputLineBuffer = Data()
        var errorBuffer = Data()
        var hasOutputEnded = false
        var hasErrorEnded = false
        var exitCode: Int32?
        var continuation: CheckedContinuation<Ending, Never>?
    }

    private static let interruptGrace: Duration = .seconds(3)
    private static let terminateGrace: Duration = .seconds(5)
    /// A grandchild can keep the pipes open after the program itself has gone.
    private static let pipeGrace: Duration = .seconds(1)
    private static let running = Mutex<[ObjectIdentifier: HelperProcess]>([:])

    private let path: String
    private let arguments: [String]
    private let onLine: (@Sendable (String) -> Void)?
    private let state = Mutex(State())
    private let process = UncheckedProcess()

    /// With `onLine`, output arrives a line at a time. Without it, output is collected and returned.
    public init(path: String, arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) {
        self.path = path
        self.arguments = arguments
        self.onLine = onLine
    }

    /// Tells every running helper to go. For when the app is quitting.
    public static func terminateAll() {
        for helper in running.withLock({ Array($0.values) }) {
            helper.process.value.terminate()
        }
    }

    /// Runs to the end. A program that can't be started counts as having failed with exit code -1.
    public func run() async -> Ending {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            stop()
        }
    }

    public func stop() {
        let hasStarted = state.withLock { state -> Bool in
            state.isStopRequested = true
            return state.hasStarted
        }
        guard hasStarted else { return }
        process.value.interrupt()
        let process = process
        Task.detached {
            try? await Task.sleep(for: Self.interruptGrace)
            guard process.value.isRunning else { return }
            process.value.terminate()
            try? await Task.sleep(for: Self.terminateGrace)
            guard process.value.isRunning else { return }
            kill(process.value.processIdentifier, SIGKILL)
        }
    }

    private func start(_ continuation: CheckedContinuation<Ending, Never>) {
        let isStopped = state.withLock { state -> Bool in
            state.continuation = continuation
            return state.isStopRequested
        }
        if isStopped {
            finish(exitCode: -1)
            return
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = process.value
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receiveOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receiveError(data)
        }
        process.terminationHandler = { [weak self] ended in
            self?.processEnded(code: ended.terminationStatus)
        }

        let identifier = ObjectIdentifier(self)
        do {
            Self.running.withLock { $0[identifier] = self }
            try process.run()
            state.withLock { $0.hasStarted = true }
            // A stop that arrived while starting had nothing to signal.
            if state.withLock({ $0.isStopRequested }) { stop() }
        } catch {
            Self.running.withLock { _ = $0.removeValue(forKey: identifier) }
            state.withLock { $0.errorBuffer = Data(error.localizedDescription.utf8) }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            finish(exitCode: -1)
        }
    }

    private func receiveOutput(_ data: Data) {
        guard let onLine else {
            state.withLock { state in
                state.outputBuffer.append(data)
                if data.isEmpty { state.hasOutputEnded = true }
            }
            finishIfEverythingEnded()
            return
        }

        let lines = state.withLock { state -> [Data] in
            state.outputLineBuffer.append(data)
            if data.isEmpty {
                state.hasOutputEnded = true
                let last = state.outputLineBuffer
                state.outputLineBuffer = Data()
                return last.isEmpty ? [] : [last]
            }
            var complete: [Data] = []
            while let newline = state.outputLineBuffer.firstIndex(of: 0x0A) {
                complete.append(state.outputLineBuffer[state.outputLineBuffer.startIndex..<newline])
                state.outputLineBuffer = Data(state.outputLineBuffer[state.outputLineBuffer.index(after: newline)...])
            }
            return complete
        }
        for line in lines {
            onLine(String(decoding: line, as: UTF8.self))
        }
        finishIfEverythingEnded()
    }

    private func receiveError(_ data: Data) {
        state.withLock { state in
            state.errorBuffer.append(data)
            if data.isEmpty { state.hasErrorEnded = true }
        }
        finishIfEverythingEnded()
    }

    private func processEnded(code: Int32) {
        state.withLock { $0.exitCode = code }
        Self.running.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
        finishIfEverythingEnded()
        Task.detached { [self] in
            try? await Task.sleep(for: Self.pipeGrace)
            finishFromState()
        }
    }

    private func finishIfEverythingEnded() {
        let isDone = state.withLock { $0.hasOutputEnded && $0.hasErrorEnded && $0.exitCode != nil }
        if isDone { finishFromState() }
    }

    private func finishFromState() {
        finish(exitCode: state.withLock { $0.exitCode ?? -1 })
    }

    private func finish(exitCode: Int32) {
        let (continuation, ending) = state.withLock { state in
            defer { state.continuation = nil }
            return (
                state.continuation,
                Ending(
                    exitCode: exitCode,
                    output: state.outputBuffer,
                    errorText: String(decoding: state.errorBuffer, as: UTF8.self)
                )
            )
        }
        continuation?.resume(returning: ending)
    }
}

/// `Process` is safe to signal from any thread, but isn't marked as such.
private final class UncheckedProcess: @unchecked Sendable {
    let value = Process()
}
#else
/// iOS can't run other programs, so anything needing one fails as if the program were missing.
public final class HelperProcess: Sendable {
    public struct Ending: Sendable {
        public let exitCode: Int32
        public let output: Data
        public let errorText: String
    }

    public init(path: String, arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) {}

    public static func terminateAll() {}

    public func run() async -> Ending {
        Ending(exitCode: -1, output: Data(), errorText: "iOS can't run other programs")
    }

    public func stop() {}
}
#endif
