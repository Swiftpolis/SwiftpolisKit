import Foundation

/// One Connection: fetches one Part at a time until none are left.
///
/// Each worker has its own session, so each gets its own TCP connection rather than sharing an
/// HTTP/2 one. The delegate runs on the worker's own queue, and blocking that queue is what slows a
/// transfer: `URLSessionTask.suspend()` keeps delivering data, so it can't be used for Pause.
final class PartWorker: RequestPolicyDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private enum Outcome {
        case completed
        case stopped
        case failed(String)
        case retryable(String, retryAfter: TimeInterval?)
    }

    /// Everything about the request in flight. It's touched only on the delegate queue, or before
    /// the task starts.
    private struct Attempt {
        let partIndex: Int
        var outcome: Outcome?
        var hasResponse = false
        var writeOffset: Int64 = 0
    }

    private unowned let engine: HTTPDownloadEngine
    private let descriptor: Int32
    private let delegateQueue: OperationQueue
    private lazy var session = requests.makeSession(delegate: self, delegateQueue: delegateQueue)

    private let lock = NSLock()
    private var currentTask: URLSessionDataTask?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var attempt: Attempt?

    init(engine: HTTPDownloadEngine, requests: RequestFactory, descriptor: Int32) {
        self.engine = engine
        self.descriptor = descriptor
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        super.init(requests: requests)
    }

    func run() async {
        while let index = engine.claimNextPart() {
            await fetch(partIndex: index)
        }
        session.finishTasksAndInvalidate()
    }

    func cancelCurrentRequest() {
        lock.withLock { currentTask }?.cancel()
    }

    // MARK: One attempt at a Part

    /// Makes one attempt, retrying temporary failures within it. Together with `claimNextPart`,
    /// this gives Persepolis's request counts: (max-tries + 1) attempts of (max-tries + 1) requests.
    private func fetch(partIndex index: Int) async {
        var failures = 0
        while true {
            switch await send(partIndex: index) {
            case .completed:
                engine.finishPart(index, status: .complete)
                return
            case .stopped:
                engine.finishPart(index, status: .stopped)
                return
            case .failed(let message):
                engine.finishPart(index, status: engine.isStopped ? .stopped : .error, message: message)
                return
            case .retryable(let message, let retryAfter):
                failures += 1
                if failures > engine.maxTries {
                    engine.finishPart(index, status: .error, message: message)
                    return
                }
                let backoff = RetryPolicy.delay(afterFailure: failures, retryWait: engine.retryWait)
                await wait(seconds: retryAfter ?? backoff)
                if engine.isStopped {
                    engine.finishPart(index, status: .stopped)
                    return
                }
            }
        }
    }

    private func wait(seconds: TimeInterval) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, !engine.isStopped {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func send(partIndex index: Int) async -> Outcome {
        var part = engine.part(index)
        var range: String?
        if engine.supportsRanges {
            let start = part.start + part.downloaded
            range = part.length.map { "bytes=\(start)-\(part.start + $0 - 1)" } ?? "bytes=\(start)-"
        } else if part.downloaded > 0 {
            engine.restartPart(index)
            part.downloaded = 0
        }

        let task = session.dataTask(with: requests.make(method: "GET", range: range))
        return await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                currentTask = task
                attempt = Attempt(partIndex: index, writeOffset: part.start + part.downloaded)
            }
            if engine.isStopped { task.cancel() }
            task.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard var attempt = lock.withLock({ self.attempt }), let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        attempt.hasResponse = true
        attempt.outcome = outcome(for: response, attempt: &attempt)
        lock.withLock { self.attempt = attempt }
        completionHandler(attempt.outcome == nil ? .allow : .cancel)
    }

    /// Decides whether to accept a response. Error pages are never written into the file.
    private func outcome(for response: HTTPURLResponse, attempt: inout Attempt) -> Outcome? {
        let status = response.statusCode
        if RetryPolicy.isRetryable(status: status) {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .retryable("HTTP error \(status)", retryAfter: retryAfter)
        }
        switch status {
        case 206:
            return nil
        case 200:
            // The server is sending the whole file. That only fits a Part starting at byte 0, and
            // anything already fetched for it has to be fetched again.
            let part = engine.part(attempt.partIndex)
            guard part.start == 0 else {
                return .failed("The server ignored the requested range")
            }
            if part.downloaded > 0 {
                engine.restartPart(attempt.partIndex)
                attempt.writeOffset = 0
            }
            return nil
        default:
            return .failed("HTTP error \(status)")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var attempt = lock.withLock({ self.attempt }), attempt.outcome == nil else { return }

        let part = engine.part(attempt.partIndex)
        var usable = data.count
        if let length = part.length {
            usable = min(usable, Int(clamping: length - part.downloaded))
        }

        if usable > 0, !write(data.prefix(usable), at: attempt.writeOffset) {
            attempt.outcome = .failed("Can't write to the file")
            lock.withLock { self.attempt = attempt }
            dataTask.cancel()
            return
        }
        attempt.writeOffset += Int64(usable)
        engine.recordDownloaded(Int64(usable), part: attempt.partIndex)

        // A server sending past the end of a Part has nothing more to offer it.
        if usable < data.count {
            attempt.outcome = .completed
            lock.withLock { self.attempt = attempt }
            dataTask.cancel()
            return
        }
        lock.withLock { self.attempt = attempt }
        holdForSpeedDialAndPause(bytes: usable)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (attempt, continuation) = lock.withLock {
            defer {
                self.attempt = nil
                self.continuation = nil
                currentTask = nil
            }
            return (self.attempt, self.continuation)
        }
        guard let attempt else { return }
        continuation?.resume(returning: finalOutcome(of: attempt, error: error))
    }

    private func finalOutcome(of attempt: Attempt, error: Error?) -> Outcome {
        if let outcome = attempt.outcome { return outcome }
        if engine.isStopped { return .stopped }
        if let error {
            let message = RequestFactory.message(for: error)
            // Failing before any response counts as a temporary failure, as it does in urllib3.
            return attempt.hasResponse ? .failed(message) : .retryable(message, retryAfter: nil)
        }
        let part = engine.part(attempt.partIndex)
        if let length = part.length, part.downloaded != length {
            return .failed("Connection error")
        }
        return .completed
    }

    // MARK: Writing and pacing

    private func write(_ data: Data, at offset: Int64) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var written = 0
            while written < buffer.count {
                let result = pwrite(
                    descriptor,
                    buffer.baseAddress! + written,
                    buffer.count - written,
                    off_t(offset) + off_t(written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += result
            }
            return true
        }
    }

    /// Blocks the delegate queue to slow or hold this Connection. Only this worker waits.
    private func holdForSpeedDialAndPause(bytes: Int) {
        let dial = engine.speedDial
        let seconds = engine.delayPerChunk(dial: dial) * Double(bytes) / Double(engine.chunkBytes)
        if seconds > 0 {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !engine.isStopped, engine.speedDial == dial {
                Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.timeIntervalSinceNow)))
            }
        }
        while engine.isPaused {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
