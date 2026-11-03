import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisTestSupport

private let mib: Int64 = 1_048_576

/// Uses an ordinary session, so this covers the engine and not what the system does with the app gone.
/// The simulator covers that: see docs/setup-and-build.md.
private struct Fixture {
    let server: MisbehavingServer
    let folder: URL
    let transfers: BackgroundTransfers
    var settings = EngineSettings()

    init(_ behaviour: MisbehavingServer.Behaviour) async throws {
        server = MisbehavingServer(behaviour)
        try await server.start()
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transfers = BackgroundTransfers(
            configuration: .ephemeral,
            folder: folder.appending(path: "Kept", directoryHint: .isDirectory)
        )
        settings.retryWait = 0
        settings.defaultFolder = folder.appending(path: "Default").path
    }

    func engine(
        gid: GID = GID(rawValue: "aaaaaaaaaaaaaaaa")!,
        link: String? = nil,
        secrets: DownloadSecrets = DownloadSecrets(),
        configure: (inout DownloadRequest) -> Void = { _ in }
    ) -> BackgroundDownloadEngine {
        var request = DownloadRequest(link: link ?? server.url(), folder: folder.path, connections: 1)
        configure(&request)
        return BackgroundDownloadEngine(gid: gid, request: request, secrets: secrets, settings: settings, transfers: transfers)
    }

    func path(_ name: String) -> String { folder.appending(path: name).path }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Background download engine")
struct BackgroundDownloadEngineTests {
    @Test("a file arrives intact, named from its link")
    func complete() async throws {
        let fixture = try await Fixture(MisbehavingServer.Behaviour(size: 3 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(link: fixture.server.url("S05E01.mkv") + "?md5=abc&expires=1")

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.fileName == "S05E01.mkv")
        #expect(engine.snapshot.filePath == fixture.path("S05E01.mkv"))
        #expect(engine.snapshot.totalBytes == 3 * mib)
        #expect(engine.snapshot.downloadedBytes == 3 * mib)
        #expect(TestContent.isIntact(path: fixture.path("S05E01.mkv"), size: 3 * mib))
    }

    @Test("the server's name beats the link's, and a chosen name beats both")
    func names() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.contentDisposition = "attachment; filename=\"server.bin\""
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let fromServer = fixture.engine()
        await fromServer.run()
        #expect(fromServer.snapshot.fileName == "server.bin")

        let chosen = fixture.engine(gid: GID(rawValue: "bbbbbbbbbbbbbbbb")!) { $0.customFileName = "chosen.bin" }
        await chosen.run()
        #expect(chosen.snapshot.fileName == "chosen.bin")
    }

    @Test("a name already taken gets a new one, and nothing is overwritten")
    func uniqueName() async throws {
        let fixture = try await Fixture(MisbehavingServer.Behaviour(size: mib))
        defer { fixture.cleanUp() }
        try Data("mine".utf8).write(to: fixture.folder.appending(path: "file.bin"))

        let engine = fixture.engine()
        await engine.run()

        #expect(engine.snapshot.fileName == "file_1.bin")
        #expect(try String(contentsOfFile: fixture.path("file.bin"), encoding: .utf8) == "mine")
    }

    @Test("in the default folder, a finished file moves to its subfolder")
    func subfolder() async throws {
        var fixture = try await Fixture(MisbehavingServer.Behaviour(size: mib))
        defer { fixture.cleanUp() }
        fixture.settings.defaultFolder = fixture.folder.path
        fixture.settings.usesSubfolders = true

        let engine = fixture.engine(link: fixture.server.url("movie.mkv"))
        await engine.run()

        #expect(engine.snapshot.filePath == fixture.path("Videos/movie.mkv"))
        #expect(engine.snapshot.totalBytes == mib)
    }

    @Test("a missing file fails at once, leaving nothing behind")
    func missing() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.getStatus = 404
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine()
        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(fixture.server.gets.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("file.bin")))
    }

    @Test("a busy server gets more tries")
    func retries() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.failFirstGets = 2
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine()
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.server.gets.count == 3)
    }

    @Test("it gives up after the allowed tries")
    func givesUp() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.getStatus = 503
        var fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        fixture.settings.maxTries = 2

        let engine = fixture.engine()
        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(fixture.server.gets.count == 2)
    }

    @Test("stopping ends the run, and starting again carries on from there")
    func stopAndResume() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 8 * mib)
        behaviour.etag = "\"v1\""
        behaviour.secondsPerMiB = 0.5
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let first = fixture.engine()
        let run = Task { await first.run() }
        await eventually { first.snapshot.downloadedBytes > mib }
        first.stop()
        await run.value
        #expect(first.snapshot.status == .stopped)

        fixture.server.resetLog()
        var fast = fixture.server.behaviour
        fast.secondsPerMiB = 0
        fixture.server.behaviour = fast
        let second = fixture.engine()
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(fixture.server.gets.first?.range != nil)
        #expect(TestContent.isIntact(path: fixture.path("file_1.bin"), size: 8 * mib)
            || TestContent.isIntact(path: fixture.path("file.bin"), size: 8 * mib))
    }

    @Test("pausing and unpausing still ends with an intact file")
    func pauseAndUnpause() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 6 * mib)
        behaviour.etag = "\"v1\""
        behaviour.secondsPerMiB = 0.3
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine()
        let run = Task { await engine.run() }
        await eventually { engine.snapshot.downloadedBytes > mib }
        engine.pause()
        #expect(engine.snapshot.status == .paused)
        try await Task.sleep(for: .milliseconds(200))
        engine.unpause()
        await run.value

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 6 * mib))
    }

    @Test("a password goes with a redirect on the same host, but not to another")
    func secretsAndRedirects() async throws {
        let target = MisbehavingServer(MisbehavingServer.Behaviour(size: mib))
        try await target.start()
        defer { target.stop() }

        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.redirectTo = target.url("real.bin", host: "localhost")
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine(secrets: DownloadSecrets(httpPassword: "secret")) { $0.httpUser = "me" }
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(target.gets.count == 1)
        #expect(target.gets.first?.headers["authorization"] == nil)
    }

    @Test("a removed Download's kept data goes with it, so its next run starts afresh")
    func discarding() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 8 * mib)
        behaviour.etag = "\"v1\""
        behaviour.secondsPerMiB = 0.5
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let gid = GID(rawValue: "cccccccccccccccc")!

        let first = fixture.engine(gid: gid)
        let run = Task { await first.run() }
        await eventually { first.snapshot.downloadedBytes > mib }
        first.stop()
        await run.value

        fixture.transfers.discard(gid)
        fixture.server.resetLog()
        var fast = fixture.server.behaviour
        fast.secondsPerMiB = 0
        fixture.server.behaviour = fast
        let second = fixture.engine(gid: gid)
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(fixture.server.gets.first?.range == nil)
    }

    @Test("stopping before anything starts ends at once")
    func stopFirst() async throws {
        let fixture = try await Fixture(MisbehavingServer.Behaviour(size: mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        engine.stop()
        await engine.run()

        #expect(engine.snapshot.status == .stopped)
        #expect(fixture.server.gets.isEmpty)
    }
}
