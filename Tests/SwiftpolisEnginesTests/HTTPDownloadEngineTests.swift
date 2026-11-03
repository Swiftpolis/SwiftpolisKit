import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisTestSupport

private let mib: Int64 = 1_048_576

/// A server, an empty folder and the settings most tests want: no waiting between retries.
private struct Fixture {
    let server: MisbehavingServer
    let folder: String
    var settings = EngineSettings()

    init(_ behaviour: MisbehavingServer.Behaviour) async throws {
        server = MisbehavingServer(behaviour)
        try await server.start()
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        settings.retryWait = 0
        settings.timeout = 5
    }

    func engine(
        name: String = "file.bin",
        connections: Int = 64,
        secrets: DownloadSecrets = DownloadSecrets(),
        configure: (inout DownloadRequest) -> Void = { _ in }
    ) -> HTTPDownloadEngine {
        var request = DownloadRequest(link: server.url(name), folder: folder, connections: connections)
        configure(&request)
        return HTTPDownloadEngine(request: request, secrets: secrets, settings: settings)
    }

    func path(_ name: String) -> String { folder + "/" + name }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func files() -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: folder).sorted()) ?? []
    }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// Waits for a condition, failing the test rather than hanging it.
private func waitUntil(
    timeout: Duration = .seconds(30),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("HTTP engine: downloading", .serialized)
struct EngineDownloadingTests {
    @Test("a large file arrives intact, as 64 Parts, and reports complete (fixes D19)")
    func largeFile() async throws {
        let fixture = try await Fixture(.init(size: 64 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        let snapshot = engine.snapshot
        #expect(snapshot.status == .complete)
        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.fileName == "file.bin")
        #expect(snapshot.totalBytes == 64 * mib)
        #expect(snapshot.downloadedBytes == 64 * mib)  // Fixes D23.
        #expect(snapshot.percent == 100)
        #expect(snapshot.activeConnections == 0)
        #expect(snapshot.filePath == fixture.path("file.bin"))
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 64 * mib))
        #expect(fixture.server.gets.count == 64)
        #expect(Set(fixture.server.gets.map(\.range)).count == 64)
        #expect(fixture.files() == ["file.bin"])
    }

    @Test("Parts run at once, but never on more Connections than asked for (fixes D4)")
    func connectionLimit() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 16 * mib)
        behaviour.secondsPerMiB = 0.2
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 4)

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.server.gets.count == 16)
        #expect(fixture.server.maximumSimultaneousGets == 4)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 16 * mib))
    }

    @Test("without range support it makes one request, for the whole file (fixes D13)")
    func noRangeSupport() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 4 * mib)
        behaviour.advertisesRanges = false
        behaviour.honoursRanges = false
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.server.gets.count == 1)
        #expect(fixture.server.gets[0].range == nil)
        #expect(fixture.server.bytesServed == 4 * mib)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 4 * mib))
    }

    @Test("an unknown size works, and the size is known by the end")
    func unknownSize() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 3 * mib)
        behaviour.sendsLength = false
        behaviour.advertisesRanges = false
        behaviour.honoursRanges = false
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.errorMessage == nil)  // Fixes D25.
        #expect(engine.snapshot.totalBytes == 3 * mib)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 3 * mib))
    }

    @Test("an empty file completes")
    func emptyFile() async throws {
        let fixture = try await Fixture(.init(size: 0))
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.files() == ["file.bin"])
    }

    @Test("a server's file name is used, without quotes (fixes D7)")
    func dispositionName() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.contentDisposition = "attachment; filename=\"report.pdf\""
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.fileName == "report.pdf")
        #expect(fixture.files() == ["report.pdf"])
    }

    @Test("a failed HEAD with an error status doesn't stop the GET")
    func headNotAllowed() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.headStatus = 405
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: mib))
    }

    @Test("not enough disk space is an error, and leaves nothing behind")
    func notEnoughSpace() async throws {
        let fixture = try await Fixture(.init(size: Int64.max / 2))
        defer { fixture.cleanUp() }
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage == "Insufficient disk space")
        #expect(fixture.files().isEmpty)
    }
}

@Suite("HTTP engine: failures", .serialized)
struct EngineFailureTests {
    @Test("dropped connections are retried, and the file ends up intact")
    func droppedConnections() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 2 * mib)
        behaviour.dropFirstGets = 3
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 1)

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.downloadedBytes == 2 * mib)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 2 * mib))
    }

    // Recorded from real Persepolis: 1 try makes 4 requests, and 2 tries make 9.
    @Test("a server stuck on 503 gets as many requests as Persepolis made", arguments: [(1, 4), (2, 9)])
    func always503(maxTries: Int, requests: Int) async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.getStatus = 503
        behaviour.headStatus = 200
        var fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        fixture.settings.maxTries = maxTries
        let engine = fixture.engine(connections: 1)

        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage == "HTTP error 503")
        #expect(fixture.server.gets.count == requests)
    }

    @Test("a temporary 503 is recovered from")
    func temporary503() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.failFirstGets = 2
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 1)

        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: mib))
    }

    @Test("a 404 ends after the normal attempts, with no request loop (fixes D20)")
    func always404() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.getStatus = 404
        var fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        fixture.settings.maxTries = 2
        let engine = fixture.engine(connections: 1)

        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage == "HTTP error 404")
        #expect(fixture.server.gets.count == 3)
    }

    @Test("an error page is never written into the file")
    func errorPageNotWritten() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.getStatus = 404
        behaviour.headStatus = 200
        var fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        fixture.settings.maxTries = 0
        let engine = fixture.engine(connections: 1)

        await engine.run()

        let data = try Data(contentsOf: URL(filePath: fixture.path("file.bin")))
        #expect(!data.contains(UInt8(ascii: "e")))
    }

    @Test("a server that ignores Range on a split file fails rather than corrupting it")
    func rangesIgnored() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 4 * mib)
        behaviour.honoursRanges = false
        var fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }
        fixture.settings.maxTries = 1
        let engine = fixture.engine(connections: 2)

        await engine.run()

        #expect(engine.snapshot.status == .error)
    }

    @Test("an unreachable server is an error, not a hang")
    func unreachable() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        fixture.server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let engine = fixture.engine()

        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage != nil)
    }
}

@Suite("HTTP engine: stopping and resuming", .serialized)
struct EngineResumeTests {
    private func slow(_ size: Int64, etag: String? = "\"v1\"") -> MisbehavingServer.Behaviour {
        var behaviour = MisbehavingServer.Behaviour(size: size)
        behaviour.secondsPerMiB = 2
        behaviour.etag = etag
        return behaviour
    }

    /// Runs until some bytes have arrived, then stops.
    private func runAndStopPartway(_ engine: HTTPDownloadEngine, after bytes: Int64 = 512 * 1024) async {
        let run = Task { await engine.run() }
        await waitUntil { engine.snapshot.downloadedBytes >= bytes }
        engine.stop()
        await run.value
    }

    @Test("stopping keeps the partial file and control file, and resuming fetches only the rest")
    func stopThenResume() async throws {
        let size = 8 * mib
        let fixture = try await Fixture(slow(size))
        defer { fixture.cleanUp() }

        let first = fixture.engine(connections: 8)
        await runAndStopPartway(first, after: 2 * mib)
        #expect(first.snapshot.status == .stopped)
        #expect(first.snapshot.activeConnections == 0)
        #expect(fixture.exists("file.bin.persepolis"))
        let downloadedBeforeStop = first.snapshot.downloadedBytes
        #expect(downloadedBeforeStop >= 2 * mib)

        fixture.server.resetLog()
        var fast = fixture.server.behaviour
        fast.secondsPerMiB = 0
        fixture.server.behaviour = fast
        let second = fixture.engine(connections: 8)
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(!fixture.exists("file.bin.persepolis"))
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: size))
        #expect(fixture.server.bytesServed <= size - downloadedBeforeStop + 8 * 128 * 1024)
    }

    @Test("stopping straight away still leaves a readable control file (fixes D21)")
    func stopEarly() async throws {
        let fixture = try await Fixture(slow(8 * mib))
        defer { fixture.cleanUp() }

        await runAndStopPartway(fixture.engine(connections: 8), after: 1)

        let data = try Data(contentsOf: URL(filePath: fixture.path("file.bin.persepolis")))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["number_of_parts"] as? Int == 8)
    }

    @Test("a changed ETag starts again as file_1.bin, leaving the old partial file, as observed")
    func changedETag() async throws {
        let size = 8 * mib
        let fixture = try await Fixture(slow(size))
        defer { fixture.cleanUp() }
        await runAndStopPartway(fixture.engine(connections: 8))

        var changed = MisbehavingServer.Behaviour(size: size)
        changed.etag = "\"v2\""
        fixture.server.behaviour = changed
        let second = fixture.engine(connections: 8)
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(second.snapshot.fileName == "file_1.bin")
        #expect(TestContent.isIntact(path: fixture.path("file_1.bin"), size: size))
        #expect(fixture.exists("file.bin"))
        #expect(fixture.exists("file.bin.persepolis"))
    }

    @Test("with no ETag, a changed size starts again instead of corrupting the file (fixes D22)")
    func changedSizeWithoutETag() async throws {
        let fixture = try await Fixture(slow(8 * mib, etag: nil))
        defer { fixture.cleanUp() }
        await runAndStopPartway(fixture.engine(connections: 8))

        fixture.server.behaviour = MisbehavingServer.Behaviour(size: 6 * mib)
        let second = fixture.engine(connections: 8)
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(second.snapshot.fileName == "file_1.bin")
        #expect(TestContent.isIntact(path: fixture.path("file_1.bin"), size: 6 * mib))
    }

    @Test("a download started in Persepolis can be finished here")
    func resumesPersepolisDownload() async throws {
        let size = 3 * mib
        var behaviour = MisbehavingServer.Behaviour(size: size)
        behaviour.etag = "\"v1\""
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        // A partial file: the first Part is done and the second is 100 KiB in, in Persepolis's format.
        var partial = TestContent.bytes(start: 0, length: Int(mib + 100 * 1024))
        partial.append(Data(count: Int(size) - partial.count))
        try partial.write(to: URL(filePath: fixture.path("file.bin")))
        var entries = [
            "[0, 1048576, \"complete\", 0]",
            "[1048576, 102400, \"downloading\", 0]",
            "[2097152, 0, \"pending\", -1]",
        ]
        entries += Array(repeating: "[3145727, 0, \"complete\", -1]", count: 61)
        let control = """
        {"ETag": "\\"v1\\"", "file_name": "file.bin", "file_size": 3145728, "number_of_parts": 3,
         "download_infromation_list": [\(entries.joined(separator: ","))]}
        """
        try Data(control.utf8).write(to: URL(filePath: fixture.path("file.bin.persepolis")))

        let engine = fixture.engine(connections: 3)
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: size))
        #expect(Set(fixture.server.gets.compactMap(\.range)) == ["bytes=1150976-2097151", "bytes=2097152-3145727"])
    }

    @Test("a finished file with the same name isn't overwritten (fixes D26)")
    func existingFileKept() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        try Data("precious".utf8).write(to: URL(filePath: fixture.path("file.bin")))

        let engine = fixture.engine()
        await engine.run()

        #expect(engine.snapshot.fileName == "file_1.bin")
        #expect(try String(contentsOfFile: fixture.path("file.bin"), encoding: .utf8) == "precious")
        #expect(TestContent.isIntact(path: fixture.path("file_1.bin"), size: mib))
    }

    @Test("pausing stops progress, and unpausing finishes the file")
    func pauseAndUnpause() async throws {
        let size = 4 * mib
        let fixture = try await Fixture(slow(size))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 2)
        let run = Task { await engine.run() }

        await waitUntil { engine.snapshot.downloadedBytes > 256 * 1024 }
        engine.pause()
        #expect(engine.snapshot.status == .paused)
        try await Task.sleep(for: .milliseconds(500))
        let held = engine.snapshot.downloadedBytes
        try await Task.sleep(for: .seconds(1))
        #expect(engine.snapshot.downloadedBytes == held)
        #expect(engine.snapshot.status == .paused)

        engine.unpause()
        #expect(engine.snapshot.status == .downloading)
        await run.value

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: size))
    }

    @Test("stopping while paused works")
    func stopWhilePaused() async throws {
        let fixture = try await Fixture(slow(4 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 2)
        let run = Task { await engine.run() }

        await waitUntil { engine.snapshot.downloadedBytes > 0 }
        engine.pause()
        engine.stop()
        await run.value

        #expect(engine.snapshot.status == .stopped)
    }

    @Test("cancelling the task stops the download")
    func cancellation() async throws {
        let fixture = try await Fixture(slow(8 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 2)
        let run = Task { await engine.run() }

        await waitUntil { engine.snapshot.downloadedBytes > 0 }
        run.cancel()
        await run.value

        #expect(engine.snapshot.status == .stopped)
    }

    @Test("progress can be read while running")
    func liveProgress() async throws {
        let fixture = try await Fixture(slow(4 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 2)
        let run = Task { await engine.run() }

        await waitUntil { engine.snapshot.bytesPerSecond > 0 && engine.snapshot.downloadedBytes > 0 }
        let snapshot = engine.snapshot
        #expect(snapshot.status == .downloading)
        #expect(snapshot.activeConnections > 0)
        #expect(snapshot.percent >= 0 && snapshot.percent < 100)
        #expect(snapshot.secondsRemaining != nil)
        await run.value
    }
}

@Suite("HTTP engine: Speed dial", .serialized)
struct EngineSpeedDialTests {
    @Test("the dial's delay slows a download by at least Persepolis's formula")
    func dialSlowsDownload() async throws {
        let fixture = try await Fixture(.init(size: 4 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 4) { $0.speedDial = 0 }

        let started = ContinuousClock.now
        await engine.run()
        let elapsed = ContinuousClock.now - started

        // Each 1 MiB Part is 10.24 chunks of 100 KiB, and each chunk waits 10 × 0.005 × 4 = 0.2 s.
        #expect(engine.snapshot.status == .complete)
        #expect(elapsed >= .seconds(2))
    }

    @Test("dial 10 adds no delay")
    func maximumDial() async throws {
        let fixture = try await Fixture(.init(size: 4 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 4) { $0.speedDial = 10 }

        let started = ContinuousClock.now
        await engine.run()

        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("the dial can change during a download")
    func changeWhileRunning() async throws {
        let fixture = try await Fixture(.init(size: 4 * mib))
        defer { fixture.cleanUp() }
        let engine = fixture.engine(connections: 1) { $0.speedDial = 0 }
        let run = Task { await engine.run() }

        await waitUntil { engine.snapshot.downloadedBytes > 0 }
        engine.setSpeedDial(10)
        await run.value

        #expect(engine.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: 4 * mib))
    }
}

@Suite("HTTP engine: requests", .serialized)
struct EngineRequestTests {
    @Test("user options go on both HEAD and GET")
    func headers() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        let cookies = fixture.path("cookies.txt")
        try """
        # Netscape HTTP Cookie File
        127.0.0.1\tFALSE\t/\tFALSE\t0\tvisible\tyes
        #HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\thidden\talso
        other.example\tFALSE\t/\tFALSE\t0\telsewhere\tno
        """.write(toFile: cookies, atomically: true, encoding: .utf8)

        let engine = fixture.engine(connections: 1, secrets: DownloadSecrets(httpPassword: "pw")) {
            $0.httpUser = "me"
            $0.referer = "https://referer.example/"
            $0.userAgent = "Observer/1"
            $0.headers = "X-One: 1\nX-Two: two words"
            $0.cookieFilePath = cookies
        }
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        for request in fixture.server.requests {
            #expect(request.headers["authorization"] == "Basic bWU6cHc=")
            #expect(request.headers["referer"] == "https://referer.example/")
            #expect(request.headers["user-agent"] == "Observer/1")
            #expect(request.headers["x-one"] == "1")
            #expect(request.headers["x-two"] == "two words")
            #expect(request.headers["accept-encoding"] == "identity")
            let cookie = try #require(request.headers["cookie"])
            #expect(cookie.contains("visible=yes"))
            #expect(cookie.contains("hidden=also"))  // Fixes D24.
            #expect(!cookie.contains("elsewhere"))
        }
        #expect(fixture.server.gets[0].range == "bytes=0-1048575")
    }

    @Test("cookies from a browser go on both HEAD and GET (fixes D8)")
    func browserCookies() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }

        let engine = fixture.engine(connections: 1, secrets: DownloadSecrets(cookieHeader: "session=abc; theme=dark"))
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        for request in fixture.server.requests {
            #expect(request.headers["cookie"] == "session=abc; theme=dark")
        }
    }

    @Test("cookies from a browser and a cookie file are both sent")
    func bothKindsOfCookies() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        let cookies = fixture.path("cookies.txt")
        try "127.0.0.1\tFALSE\t/\tFALSE\t0\tfromfile\tyes\n".write(toFile: cookies, atomically: true, encoding: .utf8)

        let engine = fixture.engine(connections: 1, secrets: DownloadSecrets(cookieHeader: "session=abc")) {
            $0.cookieFilePath = cookies
        }
        await engine.run()

        for request in fixture.server.requests {
            let header = try #require(request.headers["cookie"])
            #expect(header.contains("session=abc"))
            #expect(header.contains("fromfile=yes"))
        }
    }

    @Test("a browser's cookies aren't handed to a different host on a redirect")
    func cookiesStayOnHost() async throws {
        let target = MisbehavingServer(.init(size: mib))
        try await target.start()
        defer { target.stop() }
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.redirectTo = target.url("moved.bin", host: "localhost")
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine(connections: 1, secrets: DownloadSecrets(cookieHeader: "session=abc"))
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.server.gets[0].headers["cookie"] == "session=abc")
        #expect(target.gets.first?.headers["cookie"] == nil)
    }

    @Test("the default user agent names the app")
    func defaultUserAgent() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        await fixture.engine().run()
        #expect(fixture.server.requests[0].headers["user-agent"]?.hasPrefix("Swiftpolis/") == true)
    }

    @Test("a redirect to another host is followed, without the password")
    func crossHostRedirect() async throws {
        let target = MisbehavingServer(.init(size: mib))
        try await target.start()
        defer { target.stop() }
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.redirectTo = target.url("moved.bin", host: "localhost")
        let fixture = try await Fixture(behaviour)
        defer { fixture.cleanUp() }

        let engine = fixture.engine(connections: 1, secrets: DownloadSecrets(httpPassword: "pw")) { $0.httpUser = "me" }
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(fixture.server.gets[0].headers["authorization"] != nil)
        #expect(target.gets.first?.headers["authorization"] == nil)
        #expect(TestContent.isIntact(path: fixture.path("file.bin"), size: mib))
    }

    @Test("an HTTP proxy with a password gets an ordinary proxied GET (fixes D6)")
    func authenticatedProxy() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: mib)
        behaviour.requiredProxyAuthorization = "Basic bWU6c2VjcmV0"
        let proxy = try await Fixture(behaviour)
        defer { proxy.cleanUp() }

        var request = DownloadRequest(link: "http://files.example.test/file.bin", folder: proxy.folder, connections: 1)
        request.proxy = ProxySettings(kind: .http, host: "127.0.0.1", port: Int(proxy.server.port), user: "me")
        let engine = HTTPDownloadEngine(
            request: request,
            secrets: DownloadSecrets(proxyPassword: "secret"),
            settings: proxy.settings
        )
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(proxy.server.gets[0].target == "http://files.example.test/file.bin")
        #expect(TestContent.isIntact(path: proxy.path("file.bin"), size: mib))
    }
}

@Suite("HTTP engine: finishing", .serialized)
struct EngineFinishingTests {
    private func run(name: String, existing: [String] = []) async throws -> (DownloadSnapshot, [String], String) {
        let fixture = try await Fixture(.init(size: mib))
        var settings = fixture.settings
        settings.defaultFolder = fixture.folder
        settings.usesSubfolders = true
        for path in existing {
            let full = fixture.path(path)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: full, contents: nil)
        }
        var request = DownloadRequest(link: fixture.server.url(name), folder: fixture.folder, connections: 1)
        request.connections = 1
        let engine = HTTPDownloadEngine(request: request, secrets: DownloadSecrets(), settings: settings)
        await engine.run()
        let files = fixture.files().filter { !$0.hasSuffix("/") && $0.contains(".") || $0.contains("/") }
        defer { fixture.cleanUp() }
        return (engine.snapshot, files, fixture.folder)
    }

    @Test("a finished file moves to its subfolder inside the default folder", arguments: [
        ("song.mp3", "Audios/song.mp3"),
        ("book.mobi", "Documents/book.mobi"),
        ("thing.xyz", "Others/thing.xyz"),
    ])
    func movesToSubfolder(name: String, relative: String) async throws {
        let (snapshot, files, folder) = try await run(name: name)
        #expect(snapshot.status == .complete)
        #expect(files.contains(relative))
        #expect(snapshot.filePath == folder + "/" + relative)
    }

    @Test("a name taken in the subfolder gets a new one")
    func collision() async throws {
        let (snapshot, files, _) = try await run(name: "long.bin", existing: ["Others/long.bin"])
        #expect(files.contains("Others/long_1.bin"))
        #expect(snapshot.fileName == "long_1.bin")
    }

    @Test("a one-character name in the subfolder doesn't crash (fixes D16)")
    func oneCharacterCollision() async throws {
        let (snapshot, files, _) = try await run(name: "a.zip", existing: ["Compressed/a.zip"])
        #expect(files.contains("Compressed/a_1.zip"))
        #expect(snapshot.status == .complete)
    }

    @Test("a folder other than the default keeps the file where it is")
    func customFolder() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        var settings = fixture.settings
        settings.defaultFolder = "/somewhere/else"
        settings.usesSubfolders = true
        let request = DownloadRequest(link: fixture.server.url("song.mp3"), folder: fixture.folder, connections: 1)
        let engine = HTTPDownloadEngine(request: request, secrets: DownloadSecrets(), settings: settings)

        await engine.run()

        #expect(fixture.files() == ["song.mp3"])
    }

    @Test("subfolders can be turned off")
    func subfoldersOff() async throws {
        let fixture = try await Fixture(.init(size: mib))
        defer { fixture.cleanUp() }
        var settings = fixture.settings
        settings.defaultFolder = fixture.folder
        settings.usesSubfolders = false
        let request = DownloadRequest(link: fixture.server.url("song.mp3"), folder: fixture.folder, connections: 1)
        let engine = HTTPDownloadEngine(request: request, secrets: DownloadSecrets(), settings: settings)

        await engine.run()

        #expect(fixture.files() == ["song.mp3"])
    }
}
