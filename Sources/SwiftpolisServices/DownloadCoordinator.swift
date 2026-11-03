import Foundation
import OSLog
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisPersistence

public enum DownloadEvent: Sendable {
    /// Downloads or Categories were added, removed, reordered or edited.
    case listChanged
    /// The current state of everything running. Empty means nothing is running.
    case progress([GID: DownloadSnapshot])
    case finished(FinishedDownload)
    /// The Queues that are running now.
    case queuesChanged(Set<String>)
    case queueFinished(name: String, outcome: QueueOutcome)
    /// A requested After-download shutdown has begun, and the Mac will shut down shortly.
    case shuttingDown
}

public enum QueueOutcome: Equatable, Sendable {
    /// Every Pass ran. Some Downloads may still have failed, as in Persepolis.
    case completed
    case stoppedByUser
    /// A Download was stopped by the End time, or its whole window was missed while asleep.
    case stoppedBySchedule(message: String?)
}

public struct FinishedDownload: Equatable, Sendable {
    public let gid: GID
    public let status: DownloadStatus
    public let category: String
    public let link: String
    public let fileName: String?
    public let filePath: String?
    public let totalBytes: Int64?
    public let errorMessage: String?
}

/// Why a control action on one Download was refused.
public enum DownloadControlError: Error, Equatable, Sendable {
    /// A Queue's Downloads are controlled through the Queue.
    case managedByQueue(String)
    /// The previous session hasn't closed yet, so it's worth trying again in a moment.
    case stillClosing
    case downloadsActive
    case downloadNotFound
    case queueRunning(String)
}

/// Why one Download in a batch wasn't removed or moved as asked.
public enum DownloadRefusal: Equatable, Sendable {
    case notStopped(fileName: String)
    case fileNotFound(fileName: String)
    case notComplete(fileName: String)
    case moveFailed(fileName: String)
    case queueRunning(String)
}

/// Runs Downloads: starts their engines, reports progress, and applies Persepolis's rules about
/// who may do what. See docs/features.md.
public actor DownloadCoordinator {
    public typealias EngineFactory = @Sendable (DownloadRequest, DownloadSecrets) -> any DownloadEngine
    public typealias SpiderFunction = @Sendable (DownloadRequest, DownloadSecrets) async -> Spider.Findings

    private struct Session {
        let engine: any DownloadEngine
        /// Resumed when a Queue's Download ends, so the Queue can go on to the next.
        var onEnd: (@Sendable (DownloadSnapshot) -> Void)?
    }

    /// What a running Queue can be told while it runs. Options saved in the library don't change.
    private struct QueueRun {
        var isStopRequested = false
        var shutsDownAfterwards = false
        var speedDial = SpeedDial.maximum
        var currentDownload: GID?
    }

    public nonisolated let events: AsyncStream<DownloadEvent>
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation

    private let library: LibraryRepository
    private let secrets: any SecretStore
    private let clock: any WallClock
    private let calendar: Calendar
    private let tick: Duration
    private let queueWait: @Sendable () -> QueueWait
    private let shutDown: @Sendable () async -> Void
    private let makeEngine: EngineFactory
    private let spider: SpiderFunction

    private var sessions: [GID: Session] = [:]
    private var isTicking = false
    private var queues: [String: QueueRun] = [:]
    private var downloadsShuttingDownAfterwards: Set<GID> = []
    private var isShuttingDown = false

    /// A Queue spends at least this long on each Download, which also paces a failing one's retries.
    private static let minimumTimePerQueuedDownload: TimeInterval = 3
    private static let passesPerQueueRun = 5
    /// How long a requested shutdown waits, once everything has been told to stop.
    private static let shutdownDelay: TimeInterval = 20

    /// Progress is published every tick and saved every this many ticks, as in Persepolis.
    private static let ticksPerSave = 5
    private static let logger = Logger(subsystem: "com.amirabravesh.Swiftpolis", category: "Downloads")

    public init(
        library: LibraryRepository,
        secrets: any SecretStore,
        clock: any WallClock = SystemClock(),
        calendar: Calendar = .current,
        tick: Duration = .milliseconds(200),
        queueWait: @escaping @Sendable () -> QueueWait = { QueueWait(hours: 0, minutes: 0) },
        shutDown: @escaping @Sendable () async -> Void = {},
        makeEngine: @escaping EngineFactory,
        spider: @escaping SpiderFunction
    ) {
        self.library = library
        self.secrets = secrets
        self.clock = clock
        self.calendar = calendar
        self.tick = tick
        self.queueWait = queueWait
        self.shutDown = shutDown
        self.makeEngine = makeEngine
        self.spider = spider
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public var hasActiveDownloads: Bool { !sessions.isEmpty || !queues.isEmpty }

    // MARK: Adding

    /// Adds a Download. Only a Single Download can start straight away: a Queue's Downloads wait
    /// for the Queue.
    @discardableResult
    public func add(
        _ request: DownloadRequest,
        secrets downloadSecrets: DownloadSecrets,
        to category: String,
        startNow: Bool
    ) async throws -> GID {
        let starts = startNow && CategoryKind(categoryName: category) == .singleDownloads
        let gid = try await library.addDownload(
            request,
            to: category,
            status: starts ? .waiting : .stopped,
            at: clock.now
        )
        secrets.save(downloadSecrets, for: gid)
        eventContinuation.yield(.listChanged)

        // A scheduled Download may not run for hours, so its name and size are looked up now.
        if !starts || request.startTime != nil {
            lookUp(gid, request: request, secrets: downloadSecrets)
        }
        if starts {
            try await startSession(gid, request: request)
        }
        return gid
    }

    private func lookUp(_ gid: GID, request: DownloadRequest, secrets downloadSecrets: DownloadSecrets) {
        Task { [spider, library, eventContinuation] in
            let findings = await spider(request, downloadSecrets)
            try? await library.saveSpiderFindings(
                fileName: findings.fileName,
                totalBytes: findings.totalBytes,
                for: gid
            )
            eventContinuation.yield(.listChanged)
        }
    }

    // MARK: Control

    public func resume(_ gid: GID) async throws {
        let download = try await requireControllable(gid)
        if let session = sessions[gid] {
            guard session.engine.snapshot.status == .paused else { throw DownloadControlError.stillClosing }
            session.engine.unpause()
            return
        }
        try await startSession(gid, request: download.request)
    }

    public func pause(_ gid: GID) async throws {
        _ = try await requireControllable(gid)
        sessions[gid]?.engine.pause()
    }

    public func stop(_ gid: GID) async throws {
        _ = try await requireControllable(gid)
        downloadsShuttingDownAfterwards.remove(gid)
        sessions[gid]?.engine.stop()
    }

    /// Stops every Queue and Download. Someone who stops everything doesn't also want a shutdown.
    public func stopAll() {
        downloadsShuttingDownAfterwards.removeAll()
        stopEverything()
    }

    private func stopEverything() {
        for name in queues.keys { queues[name]?.isStopRequested = true }
        for session in sessions.values { session.engine.stop() }
    }

    public func setSpeedDial(_ dial: Int, for gid: GID) {
        sessions[gid]?.engine.setSpeedDial(dial)
    }

    /// Asks for the Mac to shut down when this Download ends. Stopping it by hand cancels this.
    public func setShutdownAfterDownload(_ isOn: Bool, for gid: GID) {
        if isOn {
            downloadsShuttingDownAfterwards.insert(gid)
        } else {
            downloadsShuttingDownAfterwards.remove(gid)
        }
    }

    private func requireControllable(_ gid: GID) async throws -> DownloadSummary {
        guard let download = try await library.download(gid) else {
            throw DownloadControlError.downloadNotFound
        }
        guard CategoryKind(categoryName: download.category) == .singleDownloads else {
            throw DownloadControlError.managedByQueue(download.category)
        }
        return download
    }

    // MARK: Running

    private func startSession(_ gid: GID, request: DownloadRequest) async throws {
        var window: ScheduleWindow?
        if request.startTime != nil || request.endTime != nil {
            window = ScheduleWindow(start: request.startTime, end: request.endTime, now: clock.now, calendar: calendar)
        }
        try await startSession(gid, request: request, window: window, speedDial: nil, onEnd: nil)
    }

    private func startSession(
        _ gid: GID,
        request: DownloadRequest,
        window: ScheduleWindow?,
        speedDial: Int?,
        onEnd: (@Sendable (DownloadSnapshot) -> Void)?
    ) async throws {
        try await library.recordStart(of: gid, status: .waiting, at: clock.now)
        var engine = makeEngine(request, secrets.load(for: gid))
        if let window {
            engine = ScheduledDownload(engine: engine, window: window, clock: clock)
        }
        if let speedDial, speedDial != SpeedDial.maximum { engine.setSpeedDial(speedDial) }
        sessions[gid] = Session(engine: engine, onEnd: onEnd)
        eventContinuation.yield(.listChanged)

        Task {
            await engine.run()
            await sessionEnded(gid, engine: engine)
        }
        startTicking()
    }

    private func sessionEnded(_ gid: GID, engine: any DownloadEngine) async {
        let snapshot = engine.snapshot
        let onEnd = sessions[gid]?.onEnd
        sessions[gid] = nil

        var category = ""
        var link = ""
        do {
            try await library.saveProgress(Self.progress(from: snapshot), for: gid)
            try await library.clearSchedule(of: gid)
            let download = try await library.download(gid)
            category = download?.category ?? ""
            link = download?.request.link ?? ""
        } catch {
            Self.logger.error("Couldn't save a finished download: \(error.localizedDescription)")
        }

        // A finished Download has no more use for a browser's login cookies. A stopped one still does.
        if snapshot.status == .complete {
            var kept = secrets.load(for: gid)
            if kept.cookieHeader != nil {
                kept.cookieHeader = nil
                secrets.save(kept, for: gid)
            }
        }

        eventContinuation.yield(.finished(FinishedDownload(
            gid: gid,
            status: snapshot.status,
            category: category,
            link: link,
            fileName: snapshot.fileName,
            filePath: snapshot.filePath,
            totalBytes: snapshot.totalBytes,
            errorMessage: snapshot.errorMessage
        )))
        eventContinuation.yield(.listChanged)
        publishProgress()
        onEnd?(snapshot)

        if downloadsShuttingDownAfterwards.remove(gid) != nil {
            beginShutdown()
        }
    }

    private func startTicking() {
        guard !isTicking else { return }
        isTicking = true
        Task { await tickWhileRunning() }
    }

    private func tickWhileRunning() async {
        var ticks = 0
        while !sessions.isEmpty {
            publishProgress()
            ticks += 1
            if ticks >= Self.ticksPerSave {
                ticks = 0
                await saveProgress()
            }
            try? await Task.sleep(for: tick)
        }
        isTicking = false
    }

    private func publishProgress() {
        eventContinuation.yield(.progress(sessions.mapValues(\.engine.snapshot)))
    }

    private func saveProgress() async {
        for gid in Array(sessions.keys) {
            guard let session = sessions[gid] else { continue }
            do {
                try await library.saveProgress(Self.progress(from: session.engine.snapshot), for: gid)
            } catch {
                Self.logger.error("Couldn't save progress: \(error.localizedDescription)")
            }
        }
    }

    private static func progress(from snapshot: DownloadSnapshot) -> DownloadProgress {
        DownloadProgress(
            status: snapshot.status,
            fileName: snapshot.fileName,
            totalBytes: snapshot.totalBytes,
            downloadedBytes: snapshot.downloadedBytes,
            filePath: snapshot.status == .complete ? snapshot.filePath : nil
        )
    }

    // MARK: Removing

    /// Takes Downloads off the list. An unfinished Download's partial files always go with it.
    /// A complete Download's file goes only if `deletingFiles` is set.
    public func remove(_ gids: [GID], deletingFiles: Bool) async throws -> [DownloadRefusal] {
        var refusals: [DownloadRefusal] = []
        var removable: [GID] = []

        for gid in gids {
            guard let download = try await library.download(gid) else { continue }
            let name = download.fileName ?? download.request.link
            if queues[download.category] != nil {
                refusals.append(.queueRunning(download.category))
                continue
            }
            guard sessions[gid] == nil, download.status.canBeRemoved else {
                refusals.append(.notStopped(fileName: name))
                continue
            }
            if !deleteFiles(of: download, deletingCompleteFile: deletingFiles) {
                refusals.append(.fileNotFound(fileName: name))
            }
            secrets.remove(for: gid)
            removable.append(gid)
        }

        try await library.removeDownloads(removable)
        eventContinuation.yield(.listChanged)
        return refusals
    }

    /// Returns false if a file that should have been deleted wasn't there.
    private func deleteFiles(of download: DownloadSummary, deletingCompleteFile: Bool) -> Bool {
        let manager = FileManager.default
        if download.status == .complete {
            guard deletingCompleteFile, let path = download.filePath else { return true }
            guard manager.fileExists(atPath: path) else { return false }
            return (try? manager.removeItem(atPath: path)) != nil
        }

        // Only a control file proves that a file of this name is this Download's. Without one, it
        // could be anything the user keeps in this folder.
        guard let name = download.fileName else { return true }
        let path = URL(filePath: download.request.folder, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory).path
        let controlPath = path + "." + "persepolis"
        guard manager.fileExists(atPath: controlPath) else { return true }
        try? manager.removeItem(atPath: controlPath)
        try? manager.removeItem(atPath: path)
        return true
    }

    /// Empties the list and removes user Queues, leaving files on disk.
    public func clearList() async throws {
        guard !hasActiveDownloads else { throw DownloadControlError.downloadsActive }
        for download in try await library.downloads(in: CategoryKind.allDownloadsName) {
            secrets.remove(for: download.gid)
        }
        try await library.clearList()
        eventContinuation.yield(.listChanged)
    }

    // MARK: Moving files

    /// Moves complete Downloads' files to another folder. A name already taken there is refused.
    public func moveFiles(_ gids: [GID], to folder: String) async throws -> [DownloadRefusal] {
        var refusals: [DownloadRefusal] = []
        let destination = URL(filePath: folder, directoryHint: .isDirectory)

        for gid in gids {
            guard let download = try await library.download(gid) else { continue }
            let name = download.fileName ?? download.request.link
            guard download.status == .complete, let path = download.filePath else {
                refusals.append(.notComplete(fileName: name))
                continue
            }
            let newPath = destination
                .appending(path: URL(filePath: path).lastPathComponent, directoryHint: .notDirectory).path
            do {
                try FileManager.default.moveItem(atPath: path, toPath: newPath)
                try await library.updateFilePath(newPath, for: gid)
            } catch {
                refusals.append(.moveFailed(fileName: name))
            }
        }
        eventContinuation.yield(.listChanged)
        return refusals
    }

    // MARK: Editing

    /// Applies the Properties window's changes.
    public func update(
        _ gid: GID,
        request: DownloadRequest,
        secrets downloadSecrets: DownloadSecrets,
        category: String
    ) async throws {
        guard sessions[gid] == nil else { throw DownloadControlError.stillClosing }
        if let current = try await library.download(gid)?.category, current != category, queues[current] != nil {
            throw DownloadControlError.queueRunning(current)
        }
        try await library.updateRequest(request, for: gid)
        try await library.moveDownload(gid, to: category)
        secrets.save(downloadSecrets, for: gid)
        eventContinuation.yield(.listChanged)
    }

    public func sort(_ category: String, by key: DownloadSortKey) async throws {
        try await library.sort(category, by: key)
        eventContinuation.yield(.listChanged)
    }

    /// Moves Downloads to another Category. They must be stopped, and their Queue must not be running.
    public func moveToCategory(_ gids: [GID], category: String) async throws -> [DownloadRefusal] {
        var refusals: [DownloadRefusal] = []
        for gid in gids {
            guard let download = try await library.download(gid) else { continue }
            if queues[download.category] != nil {
                refusals.append(.queueRunning(download.category))
            } else if sessions[gid] != nil || !download.status.canChangeCategory {
                refusals.append(.notStopped(fileName: download.fileName ?? download.request.link))
            } else {
                try await library.moveDownload(gid, to: category)
            }
        }
        eventContinuation.yield(.listChanged)
        return refusals
    }

    // MARK: Queues

    public func createQueue(named name: String) async throws {
        try await library.createQueue(named: name)
        eventContinuation.yield(.listChanged)
    }

    /// Removes a Queue and its Downloads from the list. Their files stay, as in Persepolis.
    public func removeQueue(named name: String) async throws {
        guard queues[name] == nil else { throw DownloadControlError.queueRunning(name) }
        for download in try await library.downloads(in: name) {
            secrets.remove(for: download.gid)
        }
        try await library.removeQueue(named: name)
        eventContinuation.yield(.listChanged)
    }

    public func updateQueueOptions(_ options: QueueOptions, named name: String) async throws {
        try await library.updateQueueOptions(options, named: name)
        eventContinuation.yield(.listChanged)
    }

    public func moveInQueue(_ gids: [GID], queue: String, direction: MoveDirection) async throws {
        guard queues[queue] == nil else { throw DownloadControlError.queueRunning(queue) }
        try await library.move(gids, in: queue, direction: direction)
        eventContinuation.yield(.listChanged)
    }

    public var runningQueues: Set<String> { Set(queues.keys) }

    /// Starts a Queue with its saved options. Starting one already running does nothing.
    public func startQueue(_ name: String) async throws {
        guard queues[name] == nil else { return }
        guard let options = try await library.categories().first(where: { $0.name == name })?.options else {
            throw LibraryError.categoryNotFound(name)
        }
        queues[name] = QueueRun()
        publishQueues()
        Task { await runQueue(name, options: options) }
    }

    /// Stops a Queue. Its After-download shutdown is cancelled with it.
    public func stopQueue(_ name: String) {
        guard queues[name] != nil else { return }
        queues[name]?.isStopRequested = true
        queues[name]?.shutsDownAfterwards = false
        if let current = queues[name]?.currentDownload {
            sessions[current]?.engine.stop()
        }
    }

    public func setSpeedDial(_ dial: Int, queue name: String) {
        queues[name]?.speedDial = dial
        if let current = queues[name]?.currentDownload {
            sessions[current]?.engine.setSpeedDial(dial)
        }
    }

    public func setShutdownAfterQueue(_ isOn: Bool, queue name: String) {
        queues[name]?.shutsDownAfterwards = isOn
    }

    private func publishQueues() {
        eventContinuation.yield(.queuesChanged(Set(queues.keys)))
    }

    /// See docs/queue-and-schedule.md. One Download runs at a time, over up to five Passes, and
    /// anything not complete gets another try on the next Pass.
    private func runQueue(_ name: String, options: QueueOptions) async {
        let window = ScheduleWindow(
            start: options.startTimeEnabled ? options.startTime : nil,
            end: options.endTimeEnabled ? options.endTime : nil,
            now: clock.now,
            calendar: calendar
        )
        var startedCount = 0
        var outcome = QueueOutcome.completed

        passes: for pass in 0..<Self.passesPerQueueRun {
            guard let listed = try? await library.downloads(in: name) else { break }
            let downloads = options.isReversed ? listed.reversed() : listed
            var firstStart = pass == 0 ? window.start : nil

            for download in downloads where download.status != .complete {
                if queues[name]?.isStopRequested == true {
                    outcome = .stoppedByUser
                    break passes
                }
                startedCount += 1

                var start = firstStart
                firstStart = nil
                if startedCount > 1, let waited = queueWait().startDate(after: clock.now, calendar: calendar) {
                    start = waited
                }

                let snapshot = await runQueuedDownload(
                    download,
                    queue: name,
                    window: ScheduleWindow(start: start, end: window.end)
                )
                if snapshot?.status == .stopped {
                    outcome = queues[name]?.isStopRequested == true
                        ? .stoppedByUser
                        : .stoppedBySchedule(message: snapshot?.errorMessage)
                    break passes
                }
            }
        }

        finishQueue(name, outcome: outcome)
    }

    /// Runs one Download to its end, and returns how it ended.
    private func runQueuedDownload(
        _ download: DownloadSummary,
        queue name: String,
        window: ScheduleWindow
    ) async -> DownloadSnapshot? {
        let startedAt = clock.now
        queues[name]?.currentDownload = download.gid
        let snapshot: DownloadSnapshot? = await withCheckedContinuation { continuation in
            Task {
                do {
                    try await startSession(
                        download.gid,
                        request: download.request,
                        window: window.start == nil && window.end == nil ? nil : window,
                        speedDial: queues[name]?.speedDial,
                        onEnd: { continuation.resume(returning: $0) }
                    )
                } catch {
                    Self.logger.error("Couldn't start a queued download: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
        queues[name]?.currentDownload = nil
        try? await clock.sleep(until: startedAt.addingTimeInterval(Self.minimumTimePerQueuedDownload))
        return snapshot
    }

    private func finishQueue(_ name: String, outcome: QueueOutcome) {
        let shutsDown = queues[name]?.shutsDownAfterwards == true && outcome != .stoppedByUser
        queues[name] = nil
        eventContinuation.yield(.queueFinished(name: name, outcome: outcome))
        publishQueues()
        eventContinuation.yield(.listChanged)
        if shutsDown { beginShutdown() }
    }

    // MARK: Shutting down

    /// Persepolis's sequence: say so, stop everything, wait, wait for sessions to close, shut down.
    private func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        eventContinuation.yield(.shuttingDown)
        stopEverything()
        Task {
            try? await clock.sleep(until: clock.now.addingTimeInterval(Self.shutdownDelay))
            while hasActiveDownloads {
                try? await Task.sleep(for: tick)
            }
            await shutDown()
        }
    }
}
