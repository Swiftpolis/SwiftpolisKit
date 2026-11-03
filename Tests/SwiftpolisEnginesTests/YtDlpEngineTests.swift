import Foundation
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisTestSupport
import Testing

/// A folder to download into, and a shell script standing in for yt-dlp or ffmpeg.
private struct HelperFixture {
    let root: URL
    var folder: String { root.appending(path: "downloads").path }
    var logPath: String { root.appending(path: "log.txt").path }
    var settings = EngineSettings()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root.appending(path: "downloads").path, withIntermediateDirectories: true)
    }

    /// `$CONFIG` is the config file, and `$LOG` is a file a test can read afterwards.
    func script(_ body: String) throws -> String {
        let path = root.appending(path: "helper-\(UUID().uuidString)").path
        let text = """
        #!/bin/sh
        CONFIG="$3"
        LOG="\(logPath)"
        \(body)
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    func engine(
        _ script: String,
        name: String? = "v.mp4",
        secrets: DownloadSecrets = DownloadSecrets(),
        configure: (inout DownloadRequest) -> Void = { _ in }
    ) -> YtDlpEngine {
        var request = DownloadRequest(link: "https://cdn.example/v", customFileName: name, folder: folder, connections: 1)
        request.engine = .ytDlp
        configure(&request)
        return YtDlpEngine(
            request: request,
            secrets: secrets,
            settings: settings,
            helpers: HelperPaths(ytDlp: script, ffmpeg: "/helpers/ffmpeg")
        )
    }

    var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
    func path(_ name: String) -> String { folder + "/" + name }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("yt-dlp engine")
struct YtDlpEngineTests {
    @Test func aFinishedRunIsComplete() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        echo '{"status":"downloading","downloaded_bytes":5,"total_bytes_estimate":10.0,"speed":100,"eta":3,"fragment_index":1,"fragment_count":2}'
        printf 'twelve bytes' > "\(fixture.path("v.mp4"))"
        echo '{"status":"finished","downloaded_bytes":10,"total_bytes":10}'
        """)
        let engine = fixture.engine(script)
        await engine.run()

        let snapshot = engine.snapshot
        #expect(snapshot.status == .complete)
        #expect(snapshot.fileName == "v.mp4")
        #expect(snapshot.filePath == fixture.path("v.mp4"))
        // The size on disk, which a fix-up afterwards can have changed.
        #expect(snapshot.totalBytes == 12)
        #expect(snapshot.downloadedBytes == 12)
        #expect(snapshot.fragments == nil)
    }

    @Test func progressIsVisibleWhileItRuns() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        echo '{"status":"downloading","downloaded_bytes":5,"total_bytes_estimate":10.0,"speed":100,"eta":3,"fragment_index":1,"fragment_count":2}'
        exec sleep 30
        """)
        let engine = fixture.engine(script)
        let run = Task { await engine.run() }
        await waitUntil { engine.snapshot.downloadedBytes == 5 }

        let snapshot = engine.snapshot
        #expect(snapshot.status == .downloading)
        #expect(snapshot.totalBytes == 10)
        #expect(snapshot.bytesPerSecond == 100)
        #expect(snapshot.secondsRemaining == 3)
        #expect(snapshot.fragments == "1/2")
        engine.stop()
        await run.value
    }

    @Test func stoppingEndsTheProgramAndKeepsPartialFiles() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        printf 'partial' > "\(fixture.path("v.mp4.part"))"
        echo started > "$LOG"
        exec sleep 30
        """)
        let engine = fixture.engine(script)
        let run = Task { await engine.run() }
        await waitUntil { fixture.log.contains("started") }

        let stoppedAt = ContinuousClock.now
        engine.stop()
        await run.value

        #expect(engine.snapshot.status == .stopped)
        #expect(ContinuousClock.now - stoppedAt < .seconds(10))
        #expect(fixture.exists("v.mp4.part"))
    }

    @Test func aProgramIgnoringAnInterruptIsStillEnded() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        trap '' INT
        echo started > "$LOG"
        while true; do sleep 0.2; done
        """)
        let engine = fixture.engine(script)
        let run = Task { await engine.run() }
        await waitUntil { fixture.log.contains("started") }

        engine.stop()
        await run.value
        #expect(engine.snapshot.status == .stopped)
    }

    @Test func aFailureGivesYtDlpsLastError() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        echo 'WARNING: not this' >&2
        echo 'ERROR: not this either' >&2
        echo 'ERROR: unable to download: HTTP Error 403' >&2
        exit 1
        """)
        let engine = fixture.engine(script)
        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage == "unable to download: HTTP Error 403")
    }

    @Test func exitingWithoutAFileIsAnError() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let engine = fixture.engine(try fixture.script("exit 0"))
        await engine.run()
        #expect(engine.snapshot.status == .error)
    }

    @Test func aMissingProgramIsAnError() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let engine = fixture.engine("/nonexistent/yt-dlp")
        await engine.run()
        #expect(engine.snapshot.status == .error)
    }

    @Test func secretsStayOffTheCommandLineAndInAPrivateFile() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        echo "ARGS: $*" >> "$LOG"
        stat -f 'MODE: %Lp' "$CONFIG" >> "$LOG"
        cat "$CONFIG" >> "$LOG"
        echo "CONFIGPATH: $CONFIG" >> "$LOG"
        printf x > "\(fixture.path("v.mp4"))"
        """)
        let engine = fixture.engine(script, secrets: DownloadSecrets(httpPassword: "hunter2")) {
            $0.httpUser = "me"
        }
        await engine.run()

        let log = fixture.log
        let arguments = try #require(log.split(separator: "\n").first { $0.hasPrefix("ARGS: ") })
        #expect(!arguments.contains("hunter2"))
        #expect(arguments.hasSuffix("-- https://cdn.example/v"))
        #expect(log.contains("MODE: 600"))
        #expect(log.contains("\"--password\" \"hunter2\""))

        // Nothing with a password in it stays behind.
        let line = try #require(log.split(separator: "\n").first { $0.hasPrefix("CONFIGPATH: ") })
        #expect(!FileManager.default.fileExists(atPath: String(line.dropFirst("CONFIGPATH: ".count))))
    }

    /// yt-dlp writes its cookies back over the file it read.
    @Test func theUsersCookieFileIsOnlyEverCopied() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let cookies = fixture.root.appending(path: "mine.txt").path
        let original = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tFALSE\t0\ta\t1\n"
        try original.write(toFile: cookies, atomically: true, encoding: .utf8)

        let script = try fixture.script("""
        cat "$CONFIG" >> "$LOG"
        printf x > "\(fixture.path("v.mp4"))"
        """)
        let engine = fixture.engine(script) { $0.cookieFilePath = cookies }
        await engine.run()

        #expect(fixture.log.contains("\"--cookies\""))
        #expect(!fixture.log.contains(cookies))
        #expect(try String(contentsOfFile: cookies, encoding: .utf8) == original)
    }

    @Test func aFinishedFileWithTheSameNameIsLeftAlone() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        try "mine".write(toFile: fixture.path("v.mp4"), atomically: true, encoding: .utf8)
        let script = try fixture.script("""
        cat "$CONFIG" >> "$LOG"
        printf x > "\(fixture.path("v_1.mp4"))"
        """)
        let engine = fixture.engine(script)
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.fileName == "v_1.mp4")
        #expect(fixture.log.contains(fixture.path("v_1.mp4")))
        #expect(try String(contentsOfFile: fixture.path("v.mp4"), encoding: .utf8) == "mine")
    }

    @Test func aPlaylistsNameBecomesAVideosName() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("printf x > \"\(fixture.path("show.mp4"))\"")
        let engine = fixture.engine(script, name: "show.m3u8")
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.fileName == "show.mp4")
    }

    /// D32: with subfolders off, Persepolis never set the finished file's path.
    @Test(arguments: [true, false])
    func aFinishedFileGoesWhereTheSettingsSay(usesSubfolders: Bool) async throws {
        var fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        fixture.settings.defaultFolder = fixture.folder
        fixture.settings.usesSubfolders = usesSubfolders
        let script = try fixture.script("printf x > \"\(fixture.path("v.mp4"))\"")
        let engine = fixture.engine(script)
        await engine.run()

        let expected = usesSubfolders ? fixture.path("Videos/v.mp4") : fixture.path("v.mp4")
        #expect(engine.snapshot.filePath == expected)
        #expect(FileManager.default.fileExists(atPath: expected))
    }

    @Test func stoppingBeforeRunningRunsNothing() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let engine = fixture.engine(try fixture.script("echo ran > \"$LOG\""))
        engine.stop()
        await engine.run()

        #expect(engine.snapshot.status == .stopped)
        #expect(fixture.log.isEmpty)
    }
}

@Suite("Finding formats")
struct VideoExtractorTests {
    @Test func theAnswerIsRead() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        cat "$CONFIG" >> "$LOG"
        echo '{"title": "T", "formats": [{"format_id": "a", "url": "https://s/a", "ext": "mp4", "acodec": "x", "vcodec": "y"}]}'
        """)
        let formats = try await VideoExtractor.formats(
            at: "https://site.example/watch",
            request: DownloadRequest(link: "https://site.example/watch", folder: "/tmp", connections: 1),
            secrets: DownloadSecrets(cookieHeader: "session=1"),
            settings: EngineSettings(),
            helpers: HelperPaths(ytDlp: script, deno: "/helpers/deno")
        )
        #expect(formats.title == "T")
        #expect(formats.combined.map(\.id) == ["a"])
        #expect(fixture.log.contains("\"--js-runtimes\" \"deno:/helpers/deno\""))
        #expect(fixture.log.contains("\"--dump-single-json\""))
        #expect(fixture.log.contains("\"--cookies\""))
    }

    @Test func aFailureCarriesYtDlpsWords() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let script = try fixture.script("""
        echo 'ERROR: Sign in to confirm' >&2
        exit 1
        """)
        await #expect(throws: VideoExtractor.Failure(message: "Sign in to confirm")) {
            _ = try await VideoExtractor.formats(
                at: "https://site.example/watch",
                request: DownloadRequest(link: "https://site.example/watch", folder: "/tmp", connections: 1),
                secrets: DownloadSecrets(),
                settings: EngineSettings(),
                helpers: HelperPaths(ytDlp: script)
            )
        }
    }
}

@Suite("Muxing")
struct VideoMuxerTests {
    private func streams(in fixture: HelperFixture) throws -> (video: String, audio: String) {
        let video = fixture.path("Title_video.mp4")
        let audio = fixture.path("Title_audio.m4a")
        try "vv".write(toFile: video, atomically: true, encoding: .utf8)
        try "aa".write(toFile: audio, atomically: true, encoding: .utf8)
        return (video, audio)
    }

    private let writesLastArgument = """
    for last; do :; done
    echo "$@" > "$LOG"
    printf 'muxed' > "$last"
    """

    @Test func theStreamsBecomeOneFile() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let (video, audio) = try streams(in: fixture)
        let ffmpeg = try fixture.script(writesLastArgument)

        let output = try await VideoMuxer.mux(video: video, audio: audio, folder: fixture.folder, ffmpeg: ffmpeg)

        #expect(output.fileName == "Title.mp4")
        #expect(output.path == fixture.path("Title.mp4"))
        #expect(output.bytes == 5)
        #expect(fixture.log.contains("-c copy -shortest -map 0:v:0 -map 1:a:0"))
    }

    @Test func aTakenNameGetsANumber() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let (video, audio) = try streams(in: fixture)
        try "mine".write(toFile: fixture.path("Title.mp4"), atomically: true, encoding: .utf8)
        let ffmpeg = try fixture.script(writesLastArgument)

        let output = try await VideoMuxer.mux(video: video, audio: audio, folder: fixture.folder, ffmpeg: ffmpeg)

        #expect(output.fileName == "Title_1.mp4")
        #expect(try String(contentsOfFile: fixture.path("Title.mp4"), encoding: .utf8) == "mine")
    }

    @Test func tooLittleSpaceStopsBeforeFfmpegRuns() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let (video, audio) = try streams(in: fixture)
        let ffmpeg = try fixture.script(writesLastArgument)

        await #expect(throws: VideoMuxer.Failure.notEnoughSpace(folder: fixture.folder)) {
            _ = try await VideoMuxer.mux(
                video: video, audio: audio, folder: fixture.folder, ffmpeg: ffmpeg, availableBytes: 3
            )
        }
        #expect(fixture.log.isEmpty)
    }

    @Test func aFailureLeavesNoHalfFile() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let (video, audio) = try streams(in: fixture)
        let ffmpeg = try fixture.script("""
        for last; do :; done
        printf 'half' > "$last"
        echo 'bad data' >&2
        exit 1
        """)

        await #expect(throws: VideoMuxer.Failure.failed(message: "bad data")) {
            _ = try await VideoMuxer.mux(video: video, audio: audio, folder: fixture.folder, ffmpeg: ffmpeg)
        }
        #expect(!fixture.exists("Title.mp4"))
        #expect(fixture.exists("Title_video.mp4"))
    }

    @Test func aMuxedFileGoesToVideosFromTheDefaultFolder() {
        var settings = EngineSettings()
        settings.defaultFolder = "/Downloads"
        settings.usesSubfolders = true
        #expect(VideoMuxer.folder(forDownloadIn: "/Downloads", settings: settings) == "/Downloads/Videos")
        #expect(VideoMuxer.folder(forDownloadIn: "/Other", settings: settings) == "/Other")
        settings.usesSubfolders = false
        #expect(VideoMuxer.folder(forDownloadIn: "/Downloads", settings: settings) == "/Downloads")
    }

    @Test func noFfmpegIsAFailure() async throws {
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }
        let (video, audio) = try streams(in: fixture)
        await #expect(throws: VideoMuxer.Failure.self) {
            _ = try await VideoMuxer.mux(video: video, audio: audio, folder: fixture.folder, ffmpeg: nil)
        }
    }
}

/// The real program against a local server. These run only where tools/fetch-helpers.sh has been run.
@Suite("Real yt-dlp", .enabled(if: RealHelpers.ytDlp != nil), .serialized)
struct RealYtDlpTests {
    private func engine(
        _ server: MisbehavingServer,
        folder: String,
        secrets: DownloadSecrets = DownloadSecrets(),
        configure: (inout DownloadRequest) -> Void = { _ in }
    ) -> YtDlpEngine {
        var request = DownloadRequest(link: server.url("clip.mp4"), customFileName: "clip.mp4", folder: folder, connections: 1)
        request.engine = .ytDlp
        configure(&request)
        return YtDlpEngine(
            request: request,
            secrets: secrets,
            settings: EngineSettings(),
            helpers: HelperPaths(ytDlp: RealHelpers.ytDlp, ffmpeg: RealHelpers.ffmpeg)
        )
    }

    /// D31: these are what Persepolis meant to send, and doesn't.
    @Test func aDownloadCarriesItsOptions() async throws {
        let size: Int64 = 2 * 1_048_576
        let server = MisbehavingServer(MisbehavingServer.Behaviour(size: size))
        try await server.start()
        defer { server.stop() }
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }

        let engine = engine(server, folder: fixture.folder, secrets: DownloadSecrets(cookieHeader: "session=abc")) {
            $0.userAgent = "SwiftpolisTest/1"
            $0.referer = "http://page.example/"
            $0.headers = "X-Custom: yes"
        }
        await engine.run()

        #expect(engine.snapshot.status == .complete)
        #expect(engine.snapshot.totalBytes == size)
        #expect(TestContent.isIntact(path: fixture.path("clip.mp4"), size: size))

        let get = try #require(server.gets.last)
        #expect(get.headers["user-agent"] == "SwiftpolisTest/1")
        #expect(get.headers["referer"] == "http://page.example/")
        #expect(get.headers["x-custom"] == "yes")
        #expect(get.headers["cookie"] == "session=abc")
    }

    @Test func stoppingAndStartingAgainResumes() async throws {
        let size: Int64 = 20 * 1_048_576
        var behaviour = MisbehavingServer.Behaviour(size: size)
        behaviour.secondsPerMiB = 0.5
        let server = MisbehavingServer(behaviour)
        try await server.start()
        defer { server.stop() }
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }

        let first = engine(server, folder: fixture.folder)
        let run = Task { await first.run() }
        await waitUntil(timeout: .seconds(40)) { first.snapshot.downloadedBytes > 1_048_576 }
        first.stop()
        await run.value

        #expect(first.snapshot.status == .stopped)
        #expect(fixture.exists("clip.mp4.part"))
        #expect(!fixture.exists("clip.mp4"))

        var quicker = server.behaviour
        quicker.secondsPerMiB = 0
        server.behaviour = quicker
        server.resetLog()

        let second = engine(server, folder: fixture.folder)
        await second.run()

        #expect(second.snapshot.status == .complete)
        #expect(TestContent.isIntact(path: fixture.path("clip.mp4"), size: size))
        let range = try #require(server.gets.last?.range)
        #expect(!range.hasPrefix("bytes=0-"))
    }

    @Test func aLinkThatFailsSaysWhy() async throws {
        var behaviour = MisbehavingServer.Behaviour(size: 1024)
        behaviour.getStatus = 404
        behaviour.headStatus = 404
        let server = MisbehavingServer(behaviour)
        try await server.start()
        defer { server.stop() }
        let fixture = try HelperFixture()
        defer { fixture.cleanUp() }

        let engine = engine(server, folder: fixture.folder)
        await engine.run()

        #expect(engine.snapshot.status == .error)
        #expect(engine.snapshot.errorMessage?.contains("404") == true)
    }
}

private enum RealHelpers {
    private static func helper(_ name: String) -> String? {
        let path = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Helpers/bin/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var ytDlp: String? { helper("yt-dlp") }
    static var ffmpeg: String? { helper("ffmpeg") }
}
