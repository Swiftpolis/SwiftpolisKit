import Foundation
import Synchronization
import SwiftpolisDomain

/// Fetches a file over HTTP or HTTPS using up to 64 Parts, following Persepolis's rules.
///
/// See docs/download-engine.md for the rules and docs/persepolis-observed.md for the behaviour
/// the tests are based on.
public final class HTTPDownloadEngine: DownloadEngine {
    private struct State {
        var status = DownloadStatus.waiting
        var fileName: String?
        var filePath: String?
        var fileSize: Int64?
        var etag: String?
        var supportsRanges = false
        var parts: [Part] = []
        var connections = 1
        var activeConnections = 0
        var speedDial: Int
        var bytesPerSecond = 0.0
        var errorMessage: String?
        var workers: [PartWorker] = []
        var probeSession: URLSession?
    }

    private enum PreparationError: Error {
        case insufficientSpace
        case cannotCreateFile
    }

    private let request: DownloadRequest
    private let settings: EngineSettings
    private let requests: RequestFactory
    private let state: Mutex<State>

    public init(request: DownloadRequest, secrets: DownloadSecrets, settings: EngineSettings) {
        self.request = request
        self.settings = settings
        requests = RequestFactory(request: request, secrets: secrets, settings: settings)
        state = Mutex(State(fileName: request.customFileName, speedDial: request.speedDial))
    }

    // MARK: Control

    public func run() async {
        await withTaskCancellationHandler {
            await perform()
        } onCancel: {
            stop()
        }
    }

    public func pause() {
        state.withLock { if $0.status == .downloading { $0.status = .paused } }
    }

    public func unpause() {
        state.withLock { if $0.status == .paused { $0.status = .downloading } }
    }

    public func stop() {
        let (workers, probeSession) = state.withLock { state -> ([PartWorker], URLSession?) in
            if state.status != .complete, state.status != .error { state.status = .stopped }
            return (state.workers, state.probeSession)
        }
        probeSession?.invalidateAndCancel()
        for worker in workers { worker.cancelCurrentRequest() }
    }

    public func setSpeedDial(_ dial: Int) {
        state.withLock { $0.speedDial = dial }
    }

    public var snapshot: DownloadSnapshot {
        state.withLock { state in
            let downloaded = state.parts.reduce(0) { $0 + $1.downloaded }
            var secondsRemaining: Double?
            if let size = state.fileSize, state.bytesPerSecond > 0 {
                secondsRemaining = Double(max(0, size - downloaded)) / state.bytesPerSecond
            }
            return DownloadSnapshot(
                status: state.status,
                fileName: state.fileName,
                filePath: state.filePath,
                totalBytes: state.fileSize,
                downloadedBytes: downloaded,
                activeConnections: state.activeConnections,
                bytesPerSecond: state.bytesPerSecond,
                secondsRemaining: secondsRemaining,
                errorMessage: state.errorMessage
            )
        }
    }

    // MARK: The download

    private func perform() async {
        guard move(to: .creatingDownloadFile) else { return }

        let probe: HeaderProbe
        do {
            probe = try await fetchHeaders()
        } catch {
            if !isStopped { fail(RequestFactory.message(for: error)) }
            return
        }

        let descriptor: Int32
        let controlFile: URL
        do {
            (descriptor, controlFile) = try prepareFiles(probe)
        } catch PreparationError.insufficientSpace {
            fail("Insufficient disk space")
            return
        } catch {
            fail("Can't create the file")
            return
        }
        defer { close(descriptor) }

        // Written before any worker starts, so stopping at any moment leaves a usable control file.
        writeControlFile(to: controlFile)
        guard move(to: .downloading) else { return }

        await runWorkers(descriptor: descriptor, controlFile: controlFile)
        finish(controlFile: controlFile)
    }

    /// Moves to a new status unless the Download was stopped first.
    private func move(to status: DownloadStatus) -> Bool {
        state.withLock { state in
            guard state.status != .stopped else { return false }
            state.status = status
            return true
        }
    }

    private func fail(_ message: String) {
        state.withLock { state in
            state.status = .error
            state.errorMessage = message
            state.activeConnections = 0
        }
    }

    // MARK: Asking the server

    private func fetchHeaders() async throws -> HeaderProbe {
        defer { state.withLock { $0.probeSession = nil } }
        let probe = try await HeaderProbe.fetch(requests: requests) { session in
            state.withLock { $0.probeSession = session }
            if isStopped { session.invalidateAndCancel() }
        }
        if isStopped { throw CancellationError() }
        return probe
    }

    // MARK: Preparing the files

    private func prepareFiles(_ probe: HeaderProbe) throws -> (descriptor: Int32, controlFile: URL) {
        let folder = URL(filePath: request.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func fileURL(_ name: String) -> URL { folder.appending(path: name, directoryHint: .notDirectory) }
        func controlURL(_ name: String) -> URL { fileURL("\(name).\(ControlFile.fileExtension)") }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        var name = FileNaming.fittingFileSystem(
            FileNaming.resolve(
                custom: request.customFileName,
                contentDisposition: probe.contentDisposition,
                link: request.link
            )
        )

        let controlData = try? Data(contentsOf: controlURL(name))
        let control = controlData.flatMap { try? ControlFile.decode($0) }
        var decision = ResumeDecision.decide(
            control: control,
            etag: probe.etag,
            fileSize: probe.fileSize,
            supportsRanges: probe.supportsRanges,
            fileExists: exists(fileURL(name))
        )
        // A file with no control file is finished, not partial, so it must not be overwritten.
        if controlData == nil, exists(fileURL(name)) { decision = .renameAndStartFresh }

        if decision == .renameAndStartFresh {
            name = FileNaming.unique(name) { candidate in
                exists(fileURL(candidate)) || exists(controlURL(candidate))
            }
        }

        var plan: PartPlan
        if decision == .resume, let control {
            let unfinished = control.parts.filter { $0.status != .complete }.count
            plan = PartPlan(
                parts: control.parts,
                connections: min(max(1, request.connections), max(1, unfinished))
            )
        } else {
            if let size = probe.fileSize, let free = availableCapacity(of: folder), size > free {
                throw PreparationError.insufficientSpace
            }
            plan = PartPlan.make(
                fileSize: probe.fileSize,
                supportsRanges: probe.supportsRanges,
                connections: request.connections
            )
            for index in plan.parts.indices where plan.parts[index].length == 0 {
                plan.parts[index].status = .complete
            }
        }

        let flags = decision == .resume ? O_RDWR | O_CREAT : O_RDWR | O_CREAT | O_TRUNC
        let descriptor = open(fileURL(name).path, flags, 0o644)
        guard descriptor >= 0 else { throw PreparationError.cannotCreateFile }
        if decision != .resume, let size = probe.fileSize, ftruncate(descriptor, size) != 0 {
            close(descriptor)
            throw PreparationError.cannotCreateFile
        }

        state.withLock { state in
            state.fileName = name
            state.filePath = fileURL(name).path
            state.fileSize = probe.fileSize
            state.etag = probe.etag
            state.supportsRanges = probe.supportsRanges
            state.parts = plan.parts
            state.connections = plan.connections
        }
        return (descriptor, controlURL(name))
    }

    private func availableCapacity(of folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity
            .map(Int64.init)
    }

    // MARK: Running the workers

    private func runWorkers(descriptor: Int32, controlFile: URL) async {
        let monitor = Task { await monitorProgress(controlFile: controlFile) }
        let connections = state.withLock { $0.connections }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<connections {
                // Starting all at once can get connections refused, so they start 0.1 s apart.
                if index > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                guard !isStopped, hasClaimablePart else { break }

                let worker = PartWorker(engine: self, requests: requests, descriptor: descriptor)
                state.withLock {
                    $0.workers.append(worker)
                    $0.activeConnections += 1
                }
                group.addTask { [self] in
                    await worker.run()
                    state.withLock { $0.activeConnections -= 1 }
                }
            }
        }

        monitor.cancel()
        await monitor.value
        state.withLock { $0.workers = [] }
    }

    private func monitorProgress(controlFile: URL) async {
        var previous = snapshot.downloadedBytes
        var previousTime = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            writeControlFile(to: controlFile)

            let now = ContinuousClock.now
            let downloaded = snapshot.downloadedBytes
            let elapsed = (now - previousTime).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let rate = seconds > 0 ? Double(downloaded - previous) / seconds : 0
            state.withLock { $0.bytesPerSecond = max(0, rate) }
            previous = downloaded
            previousTime = now
        }
    }

    private func writeControlFile(to url: URL) {
        let control = state.withLock { state in
            ControlFile(
                etag: state.etag,
                fileName: state.fileName ?? "",
                fileSize: state.fileSize,
                parts: state.parts
            )
        }
        try? control.encoded().write(to: url, options: .atomic)
    }

    // MARK: Finishing

    private func finish(controlFile: URL) {
        let allComplete = state.withLock { state in
            state.bytesPerSecond = 0
            state.activeConnections = 0
            return state.parts.allSatisfy { $0.status == .complete }
        }

        guard allComplete else {
            writeControlFile(to: controlFile)
            state.withLock { state in
                guard state.status != .stopped else { return }
                state.status = .error
                state.errorMessage = state.errorMessage ?? "Download error"
            }
            return
        }

        try? FileManager.default.removeItem(at: controlFile)
        let (name, path) = moveToSubfolder()
        state.withLock { state in
            state.status = .complete
            state.errorMessage = nil
            state.fileName = name
            state.filePath = path
            state.fileSize = state.parts.reduce(0) { $0 + $1.downloaded }
        }
    }

    /// Moves a finished file into its subfolder if it's in the default folder. If the move fails,
    /// the file stays where it is, as in Persepolis.
    private func moveToSubfolder() -> (name: String?, path: String?) {
        let (name, path) = state.withLock { ($0.fileName, $0.filePath) }
        guard settings.usesSubfolders, settings.defaultFolder == request.folder,
              let name, let path
        else { return (name, path) }

        let folder = URL(filePath: request.folder, directoryHint: .isDirectory)
            .appending(path: FileClassifier.subfolder(for: name), directoryHint: .isDirectory)
        let manager = FileManager.default
        let newName = FileNaming.unique(name) { candidate in
            manager.fileExists(atPath: folder.appending(path: candidate).path)
        }
        let destination = folder.appending(path: newName, directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.moveItem(atPath: path, toPath: destination.path)
            return (newName, destination.path)
        } catch {
            return (name, path)
        }
    }
}

// MARK: - What workers ask of the engine

extension HTTPDownloadEngine {
    var isStopped: Bool { state.withLock { $0.status == .stopped } }
    var isPaused: Bool { state.withLock { $0.status == .paused } }
    var supportsRanges: Bool { state.withLock { $0.supportsRanges } }
    var maxTries: Int { settings.maxTries }
    var retryWait: TimeInterval { settings.retryWait }
    var chunkBytes: Int { max(1, settings.chunkSizeKiB) * 1024 }

    private var hasClaimablePart: Bool {
        state.withLock { state in
            state.parts.contains { isClaimable($0) }
        }
    }

    private func isClaimable(_ part: Part) -> Bool {
        part.status != .complete && part.status != .downloading && part.retryCount != settings.maxTries
    }

    /// Hands out the first Part that still needs fetching and hasn't used up its attempts.
    func claimNextPart() -> Int? {
        state.withLock { state in
            guard state.status != .stopped,
                  let index = state.parts.firstIndex(where: isClaimable)
            else { return nil }
            state.parts[index].status = .downloading
            state.parts[index].retryCount += 1
            return index
        }
    }

    func part(_ index: Int) -> Part {
        state.withLock { $0.parts[index] }
    }

    func recordDownloaded(_ bytes: Int64, part index: Int) {
        state.withLock { $0.parts[index].downloaded += bytes }
    }

    func restartPart(_ index: Int) {
        state.withLock { $0.parts[index].downloaded = 0 }
    }

    func finishPart(_ index: Int, status: Part.Status, message: String? = nil) {
        state.withLock { state in
            state.parts[index].status = status
            if let message { state.errorMessage = message }
        }
    }

    var speedDial: Int { state.withLock { $0.speedDial } }

    func delayPerChunk(dial: Int) -> TimeInterval {
        SpeedDial.delayPerChunk(dial: dial, connections: state.withLock { $0.connections })
    }
}
