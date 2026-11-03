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
}

/// Why one Download in a batch wasn't removed or moved as asked.
public enum DownloadRefusal: Equatable, Sendable {
    case notStopped(fileName: String)
    case fileNotFound(fileName: String)
    case notComplete(fileName: String)
    case moveFailed(fileName: String)
}

/// Runs Downloads: starts their engines, reports progress, and applies Persepolis's rules about
/// who may do what. See docs/features.md.
public actor DownloadCoordinator {
    public typealias EngineFactory = @Sendable (DownloadRequest, DownloadSecrets) -> any DownloadEngine
    public typealias SpiderFunction = @Sendable (DownloadRequest, DownloadSecrets) async -> Spider.Findings

    private struct Session {
        let engine: any DownloadEngine
    }

    public nonisolated let events: AsyncStream<DownloadEvent>
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation

    private let library: LibraryRepository
    private let secrets: any SecretStore
    private let clock: any WallClock
    private let tick: Duration
    private let makeEngine: EngineFactory
    private let spider: SpiderFunction

    private var sessions: [GID: Session] = [:]
    private var isTicking = false

    /// Progress is published every tick and saved every this many ticks, as in Persepolis.
    private static let ticksPerSave = 5
    private static let logger = Logger(subsystem: "com.amirabravesh.Swiftpolis", category: "Downloads")

    public init(
        library: LibraryRepository,
        secrets: any SecretStore,
        clock: any WallClock = SystemClock(),
        tick: Duration = .milliseconds(200),
        makeEngine: @escaping EngineFactory,
        spider: @escaping SpiderFunction
    ) {
        self.library = library
        self.secrets = secrets
        self.clock = clock
        self.tick = tick
        self.makeEngine = makeEngine
        self.spider = spider
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public var hasActiveDownloads: Bool { !sessions.isEmpty }

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

        if starts {
            try await startSession(gid, request: request)
        } else {
            lookUp(gid, request: request, secrets: downloadSecrets)
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
        sessions[gid]?.engine.stop()
    }

    public func stopAll() {
        for session in sessions.values { session.engine.stop() }
    }

    public func setSpeedDial(_ dial: Int, for gid: GID) {
        sessions[gid]?.engine.setSpeedDial(dial)
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
        try await library.recordStart(of: gid, status: .waiting, at: clock.now)
        let engine = makeEngine(request, secrets.load(for: gid))
        sessions[gid] = Session(engine: engine)
        eventContinuation.yield(.listChanged)

        Task {
            await engine.run()
            await sessionEnded(gid, engine: engine)
        }
        startTicking()
    }

    private func sessionEnded(_ gid: GID, engine: any DownloadEngine) async {
        let snapshot = engine.snapshot
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
        guard sessions.isEmpty else { throw DownloadControlError.downloadsActive }
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
        try await library.updateRequest(request, for: gid)
        try await library.moveDownload(gid, to: category)
        secrets.save(downloadSecrets, for: gid)
        eventContinuation.yield(.listChanged)
    }

    public func sort(_ category: String, by key: DownloadSortKey) async throws {
        try await library.sort(category, by: key)
        eventContinuation.yield(.listChanged)
    }
}
