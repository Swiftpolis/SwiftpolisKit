import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisPersistence
import SwiftpolisServices
import SwiftpolisTestSupport

private final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [FakeEngine] = []

    var all: [FakeEngine] { lock.withLock { engines } }
    var last: FakeEngine? { lock.withLock { engines.last } }

    func make(_ request: DownloadRequest, _ secrets: DownloadSecrets) -> any DownloadEngine {
        let engine = FakeEngine(request: request, secrets: secrets)
        lock.withLock { engines.append(engine) }
        return engine
    }
}

/// Collects the coordinator's events as they arrive.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedDownloads: [FinishedDownload] = []
    private var progress: [[GID: DownloadSnapshot]] = []
    private var listChanges = 0

    var finished: [FinishedDownload] { lock.withLock { finishedDownloads } }
    var latestProgress: [GID: DownloadSnapshot]? { lock.withLock { progress.last } }
    var listChangeCount: Int { lock.withLock { listChanges } }

    func listen(to events: AsyncStream<DownloadEvent>) {
        Task {
            for await event in events {
                lock.withLock {
                    switch event {
                    case .finished(let download): finishedDownloads.append(download)
                    case .progress(let snapshots): progress.append(snapshots)
                    case .listChanged: listChanges += 1
                    default: break
                    }
                }
            }
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private struct Fixture {
    let library: LibraryRepository
    let secrets = InMemorySecretStore()
    let engines = EngineLog()
    let events = EventLog()
    let coordinator: DownloadCoordinator
    let folder: String

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    init(spider: Spider.Findings = Spider.Findings(fileName: "found.bin", totalBytes: 42)) async throws {
        library = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await library.prepareForLaunch()
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let engines = self.engines
        coordinator = DownloadCoordinator(
            library: library,
            secrets: secrets,
            clock: ManualClock(now: Self.now),
            tick: .milliseconds(5),
            makeEngine: { engines.make($1, $2) },
            spider: { _, _ in spider }
        )
        events.listen(to: coordinator.events)
    }

    func request(_ link: String = "https://example.com/a.zip") -> DownloadRequest {
        DownloadRequest(link: link, folder: folder, connections: 4)
    }

    /// Adds a Download that is stopped and has never run.
    func addLater(_ link: String = "https://example.com/a.zip", category: String = "Single Downloads") async throws -> GID {
        try await coordinator.add(request(link), secrets: DownloadSecrets(), to: category, startNow: false)
    }

    /// Adds a Download and waits until it's running on a fake engine.
    func addRunning(_ link: String = "https://example.com/a.zip") async throws -> (GID, FakeEngine) {
        let before = engines.all.count
        let gid = try await coordinator.add(request(link), secrets: DownloadSecrets(), to: "Single Downloads", startNow: true)
        await waitUntil { engines.all.count > before }
        return (gid, engines.last!)
    }

    func status(_ gid: GID) async throws -> DownloadStatus? {
        try await library.download(gid)?.status
    }

    func path(_ name: String) -> String { folder + "/" + name }

    func create(_ name: String) {
        FileManager.default.createFile(atPath: path(name), contents: Data("x".utf8))
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func cleanUp() { try? FileManager.default.removeItem(atPath: folder) }
}

@Suite("Download coordinator: adding")
struct CoordinatorAddingTests {
    @Test("a Single Download started now is waiting, and runs")
    func startNow() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()

        await waitUntil { engine.recordedCalls.contains("run") }
        #expect(try await fixture.library.download(gid)?.category == "Single Downloads")
        #expect(engine.request.link == "https://example.com/a.zip")
    }

    @Test("download later is stopped, and doesn't run")
    func later() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater()

        #expect(try await fixture.status(gid) == .stopped)
        #expect(fixture.engines.all.isEmpty)
    }

    @Test("adding to a Queue never starts it, even if asked to")
    func toQueue() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(), secrets: DownloadSecrets(), to: "Scheduled Downloads", startNow: true
        )

        #expect(try await fixture.status(gid) == .stopped)
        #expect(fixture.engines.all.isEmpty)
    }

    @Test("a Download that isn't started gets its name and size from the Spider")
    func spider() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater()

        try await waitUntil { try await fixture.library.download(gid)?.fileName == "found.bin" }
        #expect(try await fixture.library.download(gid)?.totalBytes == 42)
    }

    @Test("passwords go to the secret store, and reach the engine")
    func secrets() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(), secrets: DownloadSecrets(httpPassword: "pw"), to: "Single Downloads", startNow: false
        )

        #expect(fixture.secrets.load(for: gid).httpPassword == "pw")
        try await fixture.coordinator.resume(gid)
        await waitUntil { !fixture.engines.all.isEmpty }
        #expect(fixture.engines.last?.secrets.httpPassword == "pw")
    }
}

@Suite("Download coordinator: control")
struct CoordinatorControlTests {
    @Test("pause and resume reach the running engine, without starting another")
    func pauseAndResume() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()

        try await fixture.coordinator.pause(gid)  // Fixes D3.
        #expect(engine.recordedCalls.contains("pause"))

        try await waitUntil { try await fixture.status(gid) == .paused }
        try await fixture.coordinator.resume(gid)

        #expect(engine.recordedCalls.contains("unpause"))
        #expect(fixture.engines.all.count == 1)
    }

    @Test("resuming a stopped Download records the attempt and starts a new engine")
    func resumeStopped() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater()

        try await fixture.coordinator.resume(gid)

        await waitUntil { fixture.engines.all.count == 1 }
        #expect(try await fixture.library.download(gid)?.lastTryDate == Fixture.now)
    }

    @Test("a session that hasn't closed yet asks for a moment, as in Persepolis")
    func stillClosing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, _) = try await fixture.addRunning()
        try await fixture.coordinator.stop(gid)

        await #expect(throws: DownloadControlError.stillClosing) {
            try await fixture.coordinator.resume(gid)
        }
    }

    @Test("Downloads in a Queue are refused, naming the Queue")
    func queueRefusals() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater(category: "Scheduled Downloads")
        let refusal = DownloadControlError.managedByQueue("Scheduled Downloads")

        await #expect(throws: refusal) { try await fixture.coordinator.resume(gid) }
        await #expect(throws: refusal) { try await fixture.coordinator.pause(gid) }
        await #expect(throws: refusal) { try await fixture.coordinator.stop(gid) }
    }

    @Test("the Speed dial reaches the running engine")
    func speedDial() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()

        await fixture.coordinator.setSpeedDial(3, for: gid)

        #expect(engine.recordedCalls.contains("dial 3"))
    }

    @Test("stop all stops every session")
    func stopAll() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (_, first) = try await fixture.addRunning("https://example.com/1")
        let (_, second) = try await fixture.addRunning("https://example.com/2")

        await fixture.coordinator.stopAll()

        #expect(first.recordedCalls.contains("stop"))
        #expect(second.recordedCalls.contains("stop"))
    }
}

@Suite("Download coordinator: progress and finishing")
struct CoordinatorProgressTests {
    @Test("live progress is published and saved")
    func progress() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()

        engine.update {
            $0.fileName = "a.zip"
            $0.totalBytes = 100
            $0.downloadedBytes = 40
        }

        await waitUntil { fixture.events.latestProgress?[gid]?.downloadedBytes == 40 }
        try await waitUntil { try await fixture.library.download(gid)?.downloadedBytes == 40 }
        #expect(try await fixture.library.download(gid)?.fileName == "a.zip")
    }

    @Test("a finish is saved, reported once, and frees the session")
    func finishing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()

        engine.end(status: .complete) {
            $0.fileName = "a.zip"
            $0.filePath = "/x/a.zip"
            $0.totalBytes = 5
            $0.downloadedBytes = 5
        }

        await waitUntil { fixture.events.finished.count == 1 }
        let finished = try #require(fixture.events.finished.first)
        #expect(finished.gid == gid)
        #expect(finished.status == .complete)
        #expect(finished.category == "Single Downloads")
        #expect(finished.filePath == "/x/a.zip")
        #expect(finished.fileName == "a.zip")

        let saved = try #require(try await fixture.library.download(gid))
        #expect(saved.status == .complete)
        #expect(saved.filePath == "/x/a.zip")
        #expect(await fixture.coordinator.hasActiveDownloads == false)
        await waitUntil { fixture.events.latestProgress?.isEmpty == true }
    }

    @Test("a finished Download forgets its browser cookies, but keeps its passwords")
    func finishForgetsCookies() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(),
            secrets: DownloadSecrets(httpPassword: "pw", cookieHeader: "a=1"),
            to: "Single Downloads",
            startNow: true
        )
        await waitUntil { !fixture.engines.all.isEmpty }
        #expect(fixture.engines.last?.secrets.cookieHeader == "a=1")

        fixture.engines.last?.end(status: .complete)

        await waitUntil { fixture.events.finished.count == 1 }
        #expect(fixture.secrets.load(for: gid).cookieHeader == nil)
        #expect(fixture.secrets.load(for: gid).httpPassword == "pw")
    }

    @Test("a stopped Download keeps its browser cookies, for resuming")
    func stopKeepsCookies() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(), secrets: DownloadSecrets(cookieHeader: "a=1"), to: "Single Downloads", startNow: true
        )
        await waitUntil { !fixture.engines.all.isEmpty }

        fixture.engines.last?.end(status: .stopped)

        await waitUntil { fixture.events.finished.count == 1 }
        #expect(fixture.secrets.load(for: gid).cookieHeader == "a=1")
    }

    @Test("an error's message is reported")
    func errorMessage() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (_, engine) = try await fixture.addRunning()

        engine.end(status: .error) { $0.errorMessage = "HTTP error 404" }

        await waitUntil { fixture.events.finished.count == 1 }
        #expect(fixture.events.finished.first?.errorMessage == "HTTP error 404")
    }

    @Test("a finish clears the Download's schedule")
    func finishClearsSchedule() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        var request = fixture.request()
        request.startTime = ClockTime(hour: 1, minute: 0)
        let gid = try await fixture.coordinator.add(request, secrets: DownloadSecrets(), to: "Single Downloads", startNow: true)
        await waitUntil { !fixture.engines.all.isEmpty }

        // It's waiting for its Start time, so stopping ends it straight away.
        try await fixture.coordinator.stop(gid)

        await waitUntil { fixture.events.finished.count == 1 }
        #expect(try await fixture.library.download(gid)?.request.startTime == nil)
    }
}

@Suite("Download coordinator: removing")
struct CoordinatorRemovingTests {
    @Test("an active Download can't be removed, and is named in the refusal")
    func activeRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, engine) = try await fixture.addRunning()
        engine.update { $0.fileName = "a.zip" }
        try await waitUntil { try await fixture.library.download(gid)?.fileName == "a.zip" }

        let refusals = try await fixture.coordinator.remove([gid], deletingFiles: false)

        #expect(refusals == [.notStopped(fileName: "a.zip")])
        #expect(try await fixture.library.download(gid) != nil)
    }

    private func finishedPartial(_ fixture: Fixture) async throws -> GID {
        let (gid, engine) = try await fixture.addRunning()
        fixture.create("a.zip")
        fixture.create("a.zip.persepolis")
        engine.end(status: .stopped) { $0.fileName = "a.zip" }
        await waitUntil { fixture.events.finished.count == 1 }
        return gid
    }

    @Test("removing an unfinished Download deletes its partial files, even from the list only")
    func removesPartial() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await finishedPartial(fixture)

        let refusals = try await fixture.coordinator.remove([gid], deletingFiles: false)

        #expect(refusals.isEmpty)
        #expect(try await fixture.library.download(gid) == nil)
        #expect(!fixture.exists("a.zip"))
        #expect(!fixture.exists("a.zip.persepolis"))
    }

    @Test("a same-named file that isn't this Download's is left alone (fixes D28)")
    func unrelatedFileKept() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.create("found.bin")
        let gid = try await fixture.addLater()
        try await waitUntil { try await fixture.library.download(gid)?.fileName == "found.bin" }

        _ = try await fixture.coordinator.remove([gid], deletingFiles: true)

        #expect(try await fixture.library.download(gid) == nil)
        #expect(fixture.exists("found.bin"))
    }

    private func finishedComplete(_ fixture: Fixture) async throws -> GID {
        let (gid, engine) = try await fixture.addRunning()
        fixture.create("done.zip")
        let path = fixture.path("done.zip")
        engine.end(status: .complete) {
            $0.fileName = "done.zip"
            $0.filePath = path
        }
        await waitUntil { fixture.events.finished.count == 1 }
        return gid
    }

    @Test("removing a complete Download from the list keeps its file")
    func removeKeepsComplete() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await finishedComplete(fixture)

        _ = try await fixture.coordinator.remove([gid], deletingFiles: false)

        #expect(try await fixture.library.download(gid) == nil)
        #expect(fixture.exists("done.zip"))
    }

    @Test("deleting a complete Download deletes its file")
    func deleteRemovesComplete() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await finishedComplete(fixture)

        let refusals = try await fixture.coordinator.remove([gid], deletingFiles: true)

        #expect(refusals.isEmpty)
        #expect(!fixture.exists("done.zip"))
    }

    @Test("deleting a file that's already gone says so, and still removes the row")
    func deleteMissing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await finishedComplete(fixture)
        try FileManager.default.removeItem(atPath: fixture.path("done.zip"))

        let refusals = try await fixture.coordinator.remove([gid], deletingFiles: true)

        #expect(refusals == [.fileNotFound(fileName: "done.zip")])
        #expect(try await fixture.library.download(gid) == nil)
    }

    @Test("removing also forgets its passwords")
    func removesSecrets() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(), secrets: DownloadSecrets(httpPassword: "pw"), to: "Single Downloads", startNow: false
        )

        _ = try await fixture.coordinator.remove([gid], deletingFiles: false)

        #expect(fixture.secrets.load(for: gid).httpPassword == nil)
    }

    @Test("clearing the list is refused while anything is active")
    func clearRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addRunning()

        await #expect(throws: DownloadControlError.downloadsActive) {
            try await fixture.coordinator.clearList()
        }
    }

    @Test("clearing the list empties it and forgets passwords, but leaves files alone")
    func clear() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.request(), secrets: DownloadSecrets(httpPassword: "pw"), to: "Single Downloads", startNow: false
        )
        fixture.create("kept.bin")

        try await fixture.coordinator.clearList()

        #expect(try await fixture.library.downloads(in: "All Downloads").isEmpty)
        #expect(fixture.secrets.load(for: gid).httpPassword == nil)
        #expect(fixture.exists("kept.bin"))
    }
}

@Suite("Download coordinator: moving files")
struct CoordinatorMovingTests {
    private func complete(_ fixture: Fixture, name: String) async throws -> GID {
        let count = fixture.events.finished.count
        let (gid, engine) = try await fixture.addRunning("https://example.com/\(name)")
        fixture.create(name)
        let path = fixture.path(name)
        engine.end(status: .complete) {
            $0.fileName = name
            $0.filePath = path
        }
        await waitUntil { fixture.events.finished.count == count + 1 }
        return gid
    }

    @Test("a complete file moves, and its new path is remembered")
    func moves() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await complete(fixture, name: "a.zip")
        let target = fixture.path("target")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

        let refusals = try await fixture.coordinator.moveFiles([gid], to: target)

        #expect(refusals.isEmpty)
        #expect(!fixture.exists("a.zip"))
        #expect(fixture.exists("target/a.zip"))
        #expect(try await fixture.library.download(gid)?.filePath == target + "/a.zip")
    }

    @Test("an unfinished Download doesn't move")
    func unfinished() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater()
        try await waitUntil { try await fixture.library.download(gid)?.fileName == "found.bin" }

        let refusals = try await fixture.coordinator.moveFiles([gid], to: fixture.folder)

        #expect(refusals == [.notComplete(fileName: "found.bin")])
    }

    @Test("a name already taken at the destination is refused, and nothing moves")
    func nameTaken() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await complete(fixture, name: "a.zip")
        let target = fixture.path("target")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        fixture.create("target/a.zip")

        let refusals = try await fixture.coordinator.moveFiles([gid], to: target)

        #expect(refusals == [.moveFailed(fileName: "a.zip")])
        #expect(fixture.exists("a.zip"))
    }
}

@Suite("Download coordinator: editing")
struct CoordinatorEditingTests {
    @Test("properties change the options, passwords and Category")
    func edit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.addLater()
        var edited = fixture.request("https://example.com/new.zip")
        edited.connections = 2

        try await fixture.coordinator.update(
            gid, request: edited, secrets: DownloadSecrets(proxyPassword: "new"), category: "Scheduled Downloads"
        )

        let saved = try #require(try await fixture.library.download(gid))
        #expect(saved.request == edited)
        #expect(saved.category == "Scheduled Downloads")
        #expect(fixture.secrets.load(for: gid).proxyPassword == "new")
    }

    @Test("an active Download can't be edited")
    func editActive() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (gid, _) = try await fixture.addRunning()

        await #expect(throws: DownloadControlError.stillClosing) {
            try await fixture.coordinator.update(
                gid, request: fixture.request(), secrets: DownloadSecrets(), category: "Single Downloads"
            )
        }
    }
}

// The whole path with nothing faked: real engine, real store on disk, real files and a real server.
@Suite("Download coordinator: end to end", .serialized)
struct CoordinatorEndToEndTests {
    private let mib: Int64 = 1_048_576

    private func make(store: URL, library: LibraryRepository, events: EventLog) -> DownloadCoordinator {
        var settings = EngineSettings()
        settings.retryWait = 0
        settings.timeout = 5
        let frozen = settings
        let coordinator = DownloadCoordinator(
            library: library,
            secrets: InMemorySecretStore(),
            tick: .milliseconds(20),
            makeEngine: { HTTPDownloadEngine(request: $1, secrets: $2, settings: frozen) },
            spider: { await Spider.look(at: $0, secrets: $1, settings: frozen) }
        )
        events.listen(to: coordinator.events)
        return coordinator
    }

    @Test("add, pause, resume, stop, quit, reopen, resume, complete")
    func wholeLife() async throws {
        let size = 8 * mib
        var behaviour = MisbehavingServer.Behaviour(size: size)
        behaviour.etag = "\"v1\""
        behaviour.secondsPerMiB = 2
        let server = MisbehavingServer(behaviour)
        try await server.start()
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "Library.store")
        let downloads = folder.appending(path: "Downloads").path

        let gid: GID
        do {
            let library = LibraryRepository(modelContainer: try LibraryStore.makeContainer(at: store))
            try await library.prepareForLaunch()
            let events = EventLog()
            let coordinator = make(store: store, library: library, events: events)

            let request = DownloadRequest(link: server.url("movie.mkv"), folder: downloads, connections: 8)
            gid = try await coordinator.add(request, secrets: DownloadSecrets(), to: "Single Downloads", startNow: true)

            await waitUntil(timeout: .seconds(20)) { (events.latestProgress?[gid]?.downloadedBytes ?? 0) > 512 * 1024 }
            try await coordinator.pause(gid)
            try await waitUntil { try await library.download(gid)?.status == .paused }
            try await coordinator.resume(gid)
            try await waitUntil { try await library.download(gid)?.status == .downloading }

            await waitUntil(timeout: .seconds(20)) { (events.latestProgress?[gid]?.downloadedBytes ?? 0) > mib }
            try await coordinator.stop(gid)
            await waitUntil(timeout: .seconds(20)) { events.finished.count == 1 }
            #expect(events.finished.first?.status == .stopped)
            #expect(FileManager.default.fileExists(atPath: downloads + "/movie.mkv.persepolis"))
        }

        // Everything above is gone, as after quitting the app.
        server.resetLog()
        var fast = server.behaviour
        fast.secondsPerMiB = 0
        server.behaviour = fast

        let library = LibraryRepository(modelContainer: try LibraryStore.makeContainer(at: store))
        try await library.prepareForLaunch()
        let saved = try #require(try await library.download(gid))
        #expect(saved.status == .stopped)
        #expect(saved.fileName == "movie.mkv")
        #expect(saved.downloadedBytes > 0)

        let events = EventLog()
        let coordinator = make(store: store, library: library, events: events)
        try await coordinator.resume(gid)
        await waitUntil(timeout: .seconds(20)) { events.finished.count == 1 }

        let finished = try #require(events.finished.first)
        #expect(finished.status == .complete)
        #expect(TestContent.isIntact(path: downloads + "/movie.mkv", size: size))
        #expect(server.bytesServed < size)
        #expect(try await library.download(gid)?.status == .complete)
    }
}
