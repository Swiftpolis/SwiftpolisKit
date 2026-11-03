import Foundation
import Synchronization
import SwiftpolisDomain

/// The system's background downloads, which carry on while the app is suspended or gone.
///
/// One of these exists for the app's life. A Download's task is known by its GID, and what must outlast
/// the app is kept in `folder`: a finished file waiting for its Download, and resume data. See
/// docs/adr/0010-ios-downloads-belong-to-the-system.md.
public final class BackgroundTransfers: NSObject, @unchecked Sendable {
    fileprivate enum End: Sendable {
        case finished
        case cancelled
        case failed(message: String, isWorthRetrying: Bool)
    }

    private struct FinishedNote: Codable {
        var contentDisposition: String?
    }

    private struct State {
        var engines: [String: BackgroundDownloadEngine] = [:]
        /// How tasks ended while no Download was listening, as after a relaunch.
        var unclaimedEnds: [String: End] = [:]
        var refusedStatuses: [String: Int] = [:]
        var backgroundCompletion: (@Sendable () -> Void)?
    }

    /// Some servers refuse many connections at once, and this keeps a Queue roughly in order.
    private static let maximumConnectionsPerHost = 3

    private let folder: URL
    private let state = Mutex(State())
    fileprivate private(set) var session: URLSession!

    /// Tests use an ordinary configuration, as background sessions need a real app around them.
    public init(configuration: URLSessionConfiguration, folder: URL) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    /// The system woke the app to deliver events. It's told once they've all been handled.
    public func setBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
        state.withLock { $0.backgroundCompletion = completion }
    }

    /// Downloads the system still has, or finished while no Download was listening.
    public func unfinishedDownloads() async -> [GID] {
        var keys = await session.allTasks.filter { $0.state != .completed }.compactMap(\.taskDescription)
        keys += state.withLock { Array($0.unclaimedEnds.keys) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        keys += files.filter { $0.pathExtension == "finished" }.map { $0.deletingPathExtension().lastPathComponent }
        return Set(keys).sorted().compactMap(GID.init(rawValue:))
    }

    /// Forgets a Download that was removed, along with anything kept for it.
    public func discard(_ gid: GID) {
        let key = gid.rawValue
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == key { task.cancel() }
        }
        state.withLock { _ = $0.unclaimedEnds.removeValue(forKey: key) }
        for path in [finishedFile(key), finishedNote(key), resumeFile(key)] {
            try? FileManager.default.removeItem(at: path)
        }
    }

    // MARK: What a Download asks of this

    fileprivate func listen(_ key: String, engine: BackgroundDownloadEngine) {
        state.withLock { $0.engines[key] = engine }
    }

    fileprivate func stopListening(_ key: String) {
        state.withLock { _ = $0.engines.removeValue(forKey: key) }
    }

    fileprivate func claimEnd(_ key: String) -> End? {
        state.withLock { $0.unclaimedEnds.removeValue(forKey: key) }
    }

    fileprivate func existingTask(_ key: String) async -> URLSessionDownloadTask? {
        await session.allTasks
            .first { $0.taskDescription == key && $0.state != .completed && $0.state != .canceling }
            as? URLSessionDownloadTask
    }

    fileprivate func hasFinishedFile(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: finishedNote(key).path)
    }

    /// Hands over a finished file and what the server said about it.
    fileprivate func takeFinishedFile(_ key: String) -> (file: URL, contentDisposition: String?)? {
        guard let data = try? Data(contentsOf: finishedNote(key)),
              let note = try? JSONDecoder().decode(FinishedNote.self, from: data)
        else { return nil }
        return (finishedFile(key), note.contentDisposition)
    }

    fileprivate func forgetFinishedFile(_ key: String) {
        try? FileManager.default.removeItem(at: finishedNote(key))
        try? FileManager.default.removeItem(at: finishedFile(key))
    }

    fileprivate func saveResumeData(_ data: Data?, for key: String) {
        guard let data else { return }
        try? data.write(to: resumeFile(key), options: .atomic)
    }

    /// Resume data works once. If it doesn't work at all, the next try starts afresh.
    fileprivate func takeResumeData(for key: String) -> Data? {
        defer { try? FileManager.default.removeItem(at: resumeFile(key)) }
        return try? Data(contentsOf: resumeFile(key))
    }

    private func finishedFile(_ key: String) -> URL { folder.appending(path: key + ".file") }
    private func finishedNote(_ key: String) -> URL { folder.appending(path: key + ".finished") }
    private func resumeFile(_ key: String) -> URL { folder.appending(path: key + ".resume") }
}

extension BackgroundTransfers: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        state.withLock { $0.engines[key] }?.received(
            total: totalBytesWritten,
            expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
    }

    /// The system deletes this file as soon as this returns, so it's moved here and now.
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        if let status = response?.statusCode, !(200..<300).contains(status) {
            state.withLock { $0.refusedStatuses[key] = status }
            return
        }
        try? FileManager.default.removeItem(at: finishedFile(key))
        do {
            try FileManager.default.moveItem(at: location, to: finishedFile(key))
            let note = FinishedNote(contentDisposition: response?.value(forHTTPHeaderField: "Content-Disposition"))
            try JSONEncoder().encode(note).write(to: finishedNote(key), options: .atomic)
        } catch {
            state.withLock { $0.refusedStatuses[key] = 0 }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let refused = state.withLock { $0.refusedStatuses.removeValue(forKey: key) }

        let end: End
        if let refused {
            // Busy servers are worth another go, but a missing file will stay missing.
            end = .failed(message: "Request error", isWorthRetrying: refused == 429 || refused >= 500)
        } else if let error = error as? URLError {
            // Whoever cancelled has what they wanted from it, and may have discarded it since.
            if error.code != .cancelled {
                saveResumeData(error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, for: key)
            }
            end = error.code == .cancelled ? .cancelled : .failed(message: Self.message(for: error), isWorthRetrying: true)
        } else if let error {
            end = .failed(message: error.localizedDescription, isWorthRetrying: true)
        } else {
            end = .finished
        }

        let engine = state.withLock { state -> BackgroundDownloadEngine? in
            if let engine = state.engines[key] { return engine }
            if case .cancelled = end { return nil }
            state.unclaimedEnds[key] = end
            return nil
        }
        engine?.transferEnded(end, task: task)
    }

    private static func message(for error: URLError) -> String {
        error.code == .cannotWriteToFile
            ? "Can't save the file. This device may be full."
            : RequestFactory.message(for: error)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let engine = task.taskDescription.flatMap { key in state.withLock { $0.engines[key] } }
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           engine?.verifiesCertificates == false,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.backgroundCompletion = nil }
            return state.backgroundCompletion
        }
        completion?()
    }
}

/// Fetches a file through `BackgroundTransfers`, over one connection, as the system decides.
///
/// There's no Speed dial, as the app isn't there to pace anything. Pausing and stopping keep the system's
/// resume data, which works when the server gives a validator and accepts ranges.
public final class BackgroundDownloadEngine: SelfSchedulingEngine {
    private struct State {
        var status = DownloadStatus.waiting
        var fileName: String?
        var filePath: String?
        var totalBytes: Int64?
        var downloadedBytes: Int64 = 0
        var bytesPerSecond = 0.0
        var rateMeasuredAt = Date.distantPast
        var rateMeasuredBytes: Int64 = 0
        var errorMessage: String?
        var tries = 0
        var notBefore: Date?
        var task: URLSessionDownloadTask?
        /// A pause is waiting for the system's resume data, which unpausing needs.
        var isCancelling = false
        var continuation: CheckedContinuation<Void, Never>?
        var hasEnded = false
    }

    private static let rateInterval: TimeInterval = 1
    /// With nothing received for this long, the speed shown would be out of date.
    private static let rateLifetime: TimeInterval = 3

    private let key: String
    private let request: DownloadRequest
    private let settings: EngineSettings
    private let requests: RequestFactory
    private let transfers: BackgroundTransfers
    private let state: Mutex<State>

    public init(
        gid: GID,
        request: DownloadRequest,
        secrets: DownloadSecrets,
        settings: EngineSettings,
        transfers: BackgroundTransfers
    ) {
        key = gid.rawValue
        self.request = request
        self.settings = settings
        self.transfers = transfers
        requests = RequestFactory(request: request, secrets: secrets, settings: settings)
        state = Mutex(State(fileName: request.customFileName))
    }

    fileprivate var verifiesCertificates: Bool { settings.verifiesCertificates }

    // MARK: Control

    public func begin(notBefore date: Date) {
        state.withLock { $0.notBefore = date }
    }

    public func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let hasEnded = state.withLock { state -> Bool in
                    state.continuation = continuation
                    return state.hasEnded
                }
                if hasEnded {
                    continuation.resume()
                    return
                }
                transfers.listen(key, engine: self)
                Task { await pickUpOrStart() }
            }
            transfers.stopListening(key)
        } onCancel: {
            stop()
        }
    }

    public func pause() {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            guard state.status == .downloading || state.status == .scheduled else { return nil }
            state.status = .paused
            state.bytesPerSecond = 0
            state.isCancelling = state.task != nil
            defer { state.task = nil }
            return state.task
        }
        task?.cancel { [self] data in
            transfers.saveResumeData(data, for: key)
            let unpausedMeanwhile = state.withLock { state -> Bool in
                state.isCancelling = false
                return state.status == .downloading
            }
            if unpausedMeanwhile { Task { await startTask() } }
        }
    }

    public func unpause() {
        let startsNow = state.withLock { state -> Bool in
            guard state.status == .paused else { return false }
            state.status = .downloading
            return !state.isCancelling
        }
        if startsNow { Task { await startTask() } }
    }

    public func stop() {
        let (wasActive, task) = state.withLock { state -> (Bool, URLSessionDownloadTask?) in
            guard state.status != .complete, state.status != .error else { return (false, nil) }
            state.status = .stopped
            state.bytesPerSecond = 0
            defer { state.task = nil }
            return (true, state.task)
        }
        guard wasActive else { return }
        guard let task else {
            endRun()
            return
        }
        task.cancel { [self] data in
            transfers.saveResumeData(data, for: key)
            endRun()
        }
    }

    public func setSpeedDial(_ dial: Int) {}

    public var snapshot: DownloadSnapshot {
        state.withLock { state in
            let isRateCurrent = Date.now.timeIntervalSince(state.rateMeasuredAt) < Self.rateLifetime
            let rate = isRateCurrent ? state.bytesPerSecond : 0
            var secondsRemaining: Double?
            if let total = state.totalBytes, rate > 0 {
                secondsRemaining = Double(max(0, total - state.downloadedBytes)) / rate
            }
            return DownloadSnapshot(
                status: state.status,
                fileName: state.fileName,
                filePath: state.filePath,
                totalBytes: state.totalBytes,
                downloadedBytes: state.downloadedBytes,
                activeConnections: state.status == .downloading ? 1 : 0,
                bytesPerSecond: rate,
                secondsRemaining: secondsRemaining,
                errorMessage: state.errorMessage
            )
        }
    }

    // MARK: The download

    /// After a relaunch the system may already have this Download, or have finished it.
    private func pickUpOrStart() async {
        if transfers.hasFinishedFile(key) {
            finish()
        } else if let end = transfers.claimEnd(key) {
            transferEnded(end, task: nil)
        } else if let task = await transfers.existingTask(key) {
            state.withLock { state in
                guard state.status != .stopped else { return }
                state.task = task
                let isHeldBack = task.earliestBeginDate.map { $0 > .now } ?? false
                state.status = isHeldBack && task.countOfBytesReceived == 0 ? .scheduled : .downloading
                state.downloadedBytes = task.countOfBytesReceived
                if task.countOfBytesExpectedToReceive > 0 { state.totalBytes = task.countOfBytesExpectedToReceive }
            }
        } else {
            await startTask()
        }
    }

    private func startTask() async {
        var urlRequest = requests.make(method: "GET")
        urlRequest.allowsCellularAccess = settings.allowsCellularData
        if urlRequest.value(forHTTPHeaderField: "Authorization") != nil || urlRequest.value(forHTTPHeaderField: "Cookie") != nil {
            urlRequest = await withoutSecretsForOtherHosts(urlRequest)
        }

        let task = transfers.takeResumeData(for: key).map { transfers.session.downloadTask(withResumeData: $0) }
            ?? transfers.session.downloadTask(with: urlRequest)
        task.taskDescription = key
        let shouldResume = state.withLock { state -> Bool in
            guard state.status != .stopped, state.status != .paused else { return false }
            if let notBefore = state.notBefore, notBefore > .now {
                task.earliestBeginDate = notBefore
                state.status = .scheduled
            } else {
                state.status = .downloading
            }
            state.task = task
            return true
        }
        if shouldResume { task.resume() } else { task.cancel() }
    }

    /// Tasks in a background session follow redirects with no say from the app, sending these headers
    /// along. So the redirects are followed first, and a password or cookies only go if the file
    /// is on the same host.
    private func withoutSecretsForOtherHosts(_ urlRequest: URLRequest) async -> URLRequest {
        let delegate = RequestPolicyDelegate(requests: requests)
        let session = requests.makeSession(delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: requests.make(method: "HEAD")),
              let finalURL = response.url
        else { return urlRequest }

        var result = urlRequest
        result.url = finalURL
        if finalURL.host != urlRequest.url?.host {
            result.setValue(nil, forHTTPHeaderField: "Authorization")
            result.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return result
    }

    fileprivate func received(total: Int64, expected: Int64?) {
        state.withLock { state in
            if state.status == .scheduled { state.status = .downloading }
            state.downloadedBytes = total
            if let expected { state.totalBytes = expected }

            let now = Date.now
            let elapsed = now.timeIntervalSince(state.rateMeasuredAt)
            guard elapsed >= Self.rateInterval else { return }
            if elapsed < Self.rateLifetime {
                state.bytesPerSecond = max(0, Double(total - state.rateMeasuredBytes) / elapsed)
            }
            state.rateMeasuredAt = now
            state.rateMeasuredBytes = total
        }
    }

    /// A task this engine has let go of can still report, and can even reach the next run of the same
    /// Download, so only the current task counts.
    fileprivate func transferEnded(_ end: BackgroundTransfers.End, task: URLSessionTask?) {
        let isCurrent = state.withLock { state -> Bool in
            guard state.task === task else { return false }
            state.task = nil
            return true
        }
        guard isCurrent else { return }
        switch end {
        case .finished:
            finish()
        case .cancelled:
            fail("Request error")
        case .failed(let message, let isWorthRetrying):
            handleFailure(message, isWorthRetrying: isWorthRetrying)
        }
    }

    private func handleFailure(_ message: String, isWorthRetrying: Bool) {
        let triesAgain = state.withLock { state -> Bool in
            state.tries += 1
            return isWorthRetrying && state.tries < settings.maxTries
        }
        guard triesAgain else {
            fail(message)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(settings.retryWait))
            let isStillWanted = state.withLock { $0.status == .downloading || $0.status == .scheduled }
            if isStillWanted { await startTask() }
        }
    }

    private func fail(_ message: String) {
        state.withLock { state in
            guard state.status != .stopped else { return }
            state.status = .error
            state.errorMessage = message
            state.bytesPerSecond = 0
        }
        endRun()
    }

    /// Puts the finished file where the Download said it should go.
    private func finish() {
        guard let finished = transfers.takeFinishedFile(key) else {
            fail("Download error")
            return
        }
        let folder = URL(filePath: request.folder, directoryHint: .isDirectory)
        let manager = FileManager.default
        let name = FileNaming.unique(
            FileNaming.fittingFileSystem(
                FileNaming.resolve(
                    custom: request.customFileName,
                    contentDisposition: finished.contentDisposition,
                    link: request.link
                )
            )
        ) { manager.fileExists(atPath: folder.appending(path: $0, directoryHint: .notDirectory).path) }
        let destination = folder.appending(path: name, directoryHint: .notDirectory)

        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.moveItem(at: finished.file, to: destination)
        } catch {
            fail("Can't create the file")
            return
        }
        transfers.forgetFinishedFile(key)

        let moved = FinishedFile.moveToSubfolder(name: name, path: destination.path, request: request, settings: settings)
        let size = (try? URL(filePath: moved.path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        state.withLock { state in
            state.status = .complete
            state.errorMessage = nil
            state.fileName = moved.name
            state.filePath = moved.path
            state.totalBytes = size ?? state.totalBytes
            state.downloadedBytes = state.totalBytes ?? state.downloadedBytes
            state.bytesPerSecond = 0
        }
        endRun()
    }

    private func endRun() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.hasEnded = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
