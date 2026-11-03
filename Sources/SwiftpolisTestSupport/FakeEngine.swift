import Foundation
import SwiftpolisDomain
import SwiftpolisEngines

/// An engine a test drives by hand. `run()` only returns once the test ends it.
public final class FakeEngine: DownloadEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var current: DownloadSnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasEnded = false
    private var calls: [String] = []

    public let request: DownloadRequest
    public let secrets: DownloadSecrets

    public init(request: DownloadRequest, secrets: DownloadSecrets) {
        self.request = request
        self.secrets = secrets
        current = DownloadSnapshot(
            status: .downloading,
            fileName: request.customFileName,
            filePath: nil,
            totalBytes: nil,
            downloadedBytes: 0,
            activeConnections: 1,
            bytesPerSecond: 0,
            secondsRemaining: nil,
            errorMessage: nil
        )
    }

    public var recordedCalls: [String] { lock.withLock { calls } }

    public func run() async {
        record("run")
        await withCheckedContinuation { continuation in
            let shouldReturn = lock.withLock {
                if hasEnded { return true }
                self.continuation = continuation
                return false
            }
            if shouldReturn { continuation.resume() }
        }
    }

    public func pause() {
        record("pause")
        lock.withLock { current.status = .paused }
    }

    public func unpause() {
        record("unpause")
        lock.withLock { current.status = .downloading }
    }

    /// Asks the engine to stop. As with the real one, `run()` returns a moment later, so a test
    /// can see the time in between. Use `end` to finish.
    public func stop() {
        record("stop")
        lock.withLock { current.status = .stopped }
    }

    public func setSpeedDial(_ dial: Int) {
        record("dial \(dial)")
    }

    public var snapshot: DownloadSnapshot {
        lock.withLock { current }
    }

    public func update(_ change: (inout DownloadSnapshot) -> Void) {
        lock.withLock { change(&current) }
    }

    /// Ends `run()`, optionally setting the final status first.
    public func end(status: DownloadStatus? = nil, change: (inout DownloadSnapshot) -> Void = { _ in }) {
        let continuation = lock.withLock {
            if let status { current.status = status }
            change(&current)
            current.activeConnections = 0
            hasEnded = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }
}
