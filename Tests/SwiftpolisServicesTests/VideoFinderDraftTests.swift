import Foundation
import SwiftpolisBridge
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisServices
import Testing

private func format(_ id: String, ext: String = "mp4", video: Bool = true, audio: Bool = true, proto: String = "https") -> String {
    """
    {"format_id": "\(id)", "url": "https://s.example/\(id)", "ext": "\(ext)", "protocol": "\(proto)",
     "acodec": "\(audio ? "mp4a" : "none")", "vcodec": "\(video ? "avc1" : "none")"}
    """
}

private func formats(_ list: [String], title: String = "My video") throws -> VideoFormats {
    try VideoFormats(json: Data("""
    {"title": "\(title)", "formats": [\(list.joined(separator: ","))]}
    """.utf8))
}

private let separateStreams = [
    format("c1"),
    format("a1", ext: "m4a", video: false),
    format("a2", ext: "opus", video: false),
    format("v1", audio: false),
    format("v2", ext: "webm", audio: false),
]

@Suite("Video Finder draft")
struct VideoFinderDraftTests {
    private func draft(_ found: VideoFormats, category: String? = nil) -> VideoFinderDraft {
        var options = DownloadDraft(preferences: Preferences())
        options.link = "https://www.youtube.com/watch?v=abc"
        options.folder = "/Downloads"
        options.connections = 16
        if let category { options.category = category }
        var draft = VideoFinderDraft(options: options)
        draft.apply(found)
        return draft
    }

    @Test func withSeparateStreamsBestQualityIsChosen() throws {
        let draft = draft(try formats(separateStreams))
        #expect(draft.mediaChoice == .bestQuality)
        #expect(draft.videoChoice == 1)
        #expect(draft.audioChoice == 1)
        #expect(draft.name == "My video")
        #expect(draft.changesName)
        #expect(draft.fileExtension == ".webm")
    }

    @Test func withoutThemTheBestCombinedFormatIsChosen() throws {
        let draft = draft(try formats([format("c1"), format("c2", ext: "mkv")]))
        #expect(draft.mediaChoice == .combined(1))
        #expect(draft.fileExtension == ".mkv")
        #expect(!draft.canChooseSeparateStreams)
    }

    @Test func onlyVideoStreamsForceTheSeparateLists() throws {
        let draft = draft(try formats([format("v1", audio: false)]))
        #expect(draft.usesSeparateStreams)
        #expect(!draft.canChooseSeparateStreams)
        #expect(!draft.showsMediaPicker)
        guard case .single(let request, _) = draft.plan else {
            Issue.record("Expected one Download")
            return
        }
        #expect(request.link == "https://s.example/v1")
    }

    @Test func theFormatsHeadersFillTheOptions() throws {
        let found = try VideoFormats(json: Data("""
        {"formats": [{"format_id": "a", "url": "https://s/a", "ext": "mp4", "acodec": "x", "vcodec": "y",
         "http_headers": {"User-Agent": "UA", "Referer": "https://r/", "Accept": "*/*"}}]}
        """.utf8))
        let draft = draft(found)
        #expect(draft.options.userAgent == "UA")
        #expect(draft.options.referer == "https://r/")
        #expect(draft.options.headers == "Accept: */*")
    }

    @Test func bestQualityIsAPairOfTheLastStreams() throws {
        let draft = draft(try formats(separateStreams))
        guard case .pair(let video, let audio, _) = draft.plan else {
            Issue.record("Expected a pair")
            return
        }
        #expect(video.link == "https://s.example/v2")
        #expect(audio.link == "https://s.example/a2")
        #expect(video.customFileName == "My video_video.webm")
        #expect(audio.customFileName == "My video_audio.opus")
        #expect(video.engine == .ytDlp)
        #expect(audio.engine == .ytDlp)
        #expect(video.connections == 16)
        #expect(video.folder == "/Downloads")
        #expect(video.speedDial == 10)
    }

    @Test func aChosenCombinedFormatIsOneDownload() throws {
        var draft = draft(try formats(separateStreams))
        draft.mediaChoice = .combined(0)
        guard case .single(let request, _) = draft.plan else {
            Issue.record("Expected one Download")
            return
        }
        #expect(request.link == "https://s.example/c1")
        #expect(request.customFileName == "My video.mp4")
        #expect(request.engine == .http)
    }

    /// D34: Persepolis sends these to the HTTP engine, which saves the playlist's text as the video.
    @Test(arguments: ["m3u8_native", "m3u8", "http_dash_segments"])
    func aPlaylistFormatGoesToYtDlp(proto: String) throws {
        let draft = draft(try formats([format("h", proto: proto)]))
        guard case .single(let request, _) = draft.plan else {
            Issue.record("Expected one Download")
            return
        }
        #expect(request.engine == .ytDlp)
        #expect(request.customFileName == "My video.mp4")
    }

    @Test func theAdvancedListsChooseStreams() throws {
        var draft = draft(try formats(separateStreams))
        draft.usesSeparateStreams = true

        draft.videoChoice = 0
        draft.audioChoice = 0
        #expect(draft.fileExtension == ".mp4")
        guard case .pair(let video, let audio, _) = draft.plan else {
            Issue.record("Expected a pair")
            return
        }
        #expect(video.link == "https://s.example/v1")
        #expect(audio.link == "https://s.example/a1")
        #expect(audio.customFileName == "My video_audio.m4a")

        draft.videoChoice = nil
        #expect(draft.fileExtension == ".m4a")
        guard case .single(let audioOnly, _) = draft.plan else {
            Issue.record("Expected one Download")
            return
        }
        #expect(audioOnly.link == "https://s.example/a1")
        #expect(audioOnly.customFileName == "My video.m4a")

        draft.videoChoice = 1
        draft.audioChoice = nil
        guard case .single(let videoOnly, _) = draft.plan else {
            Issue.record("Expected one Download")
            return
        }
        #expect(videoOnly.link == "https://s.example/v2")

        draft.videoChoice = nil
        #expect(draft.plan == nil)
    }

    @Test func noNameMeansTheDefaultName() throws {
        var draft = draft(try formats([format("c1")]))
        draft.changesName = false
        guard case .single(let request, _) = draft.plan else { return }
        #expect(request.customFileName == "video_finder_file.mp4")

        draft.changesName = true
        draft.name = "   "
        guard case .single(let blank, _) = draft.plan else { return }
        #expect(blank.customFileName == "video_finder_file.mp4")
    }

    @Test func refererFallsBackToThePage() throws {
        let draft = draft(try formats([format("c1")]))
        guard case .single(let request, _) = draft.plan else { return }
        #expect(request.referer == "https://www.youtube.com/watch?v=abc")
    }

    @Test func aStartTimeIsOnTheVideoOnlyAndAnEndTimeOnBoth() throws {
        var draft = draft(try formats(separateStreams))
        draft.options.usesStartTime = true
        draft.options.startTime = ClockTime(hour: 1, minute: 0)!
        draft.options.usesEndTime = true
        draft.options.endTime = ClockTime(hour: 2, minute: 0)!
        guard case .pair(let video, let audio, _) = draft.plan else { return }
        #expect(video.startTime == ClockTime(hour: 1, minute: 0))
        #expect(audio.startTime == nil)
        #expect(video.endTime == ClockTime(hour: 2, minute: 0))
        #expect(audio.endTime == ClockTime(hour: 2, minute: 0))
    }

    @Test func aBrowsersCookiesTravelWithTheStreams() throws {
        var draft = draft(try formats(separateStreams))
        draft.options.cookieHeader = "session=1"
        guard case .pair(_, _, let secrets) = draft.plan else { return }
        #expect(secrets.cookieHeader == "session=1")
    }
}

@Suite("Routing browser requests to Video Finder")
struct VideoFinderRoutingTests {
    private let video = BrowserLink(url: "https://www.youtube.com/watch?v=1")
    private let video2 = BrowserLink(url: "https://vimeo.com/2")
    private let plain = BrowserLink(url: "https://example.com/a.zip")

    @Test func videoLinksGoToVideoFinderAndTheRestAsUsual() {
        let plan = BrowserRequestPlan(links: [video, plain], startsImmediately: false, videoFinderMaxLinks: 3)
        #expect(plan.videoFinder == [video])
        #expect(plan.route == .addLink(plain))
    }

    @Test func linksBeyondTheLimitAreHandledAsNormalLinks() {
        let plan = BrowserRequestPlan(links: [video, video2, plain], startsImmediately: false, videoFinderMaxLinks: 1)
        #expect(plan.videoFinder == [video])
        #expect(plan.route == .batch([video2, plain]))
    }

    @Test func aLimitOfZeroTurnsItOff() {
        let plan = BrowserRequestPlan(links: [video], startsImmediately: true, videoFinderMaxLinks: 0)
        #expect(plan.videoFinder.isEmpty)
        #expect(plan.route == .startNow(video))
    }

    @Test func onlyVideoLinksLeaveNothingElse() {
        let plan = BrowserRequestPlan(links: [video, video2], startsImmediately: false, videoFinderMaxLinks: 3)
        #expect(plan.videoFinder == [video, video2])
        #expect(plan.route == nil)
    }
}

@Suite("Drafts choosing an engine")
struct DownloadDraftEngineTests {
    @Test func aNameEndingInM3u8GoesToYtDlp() {
        var draft = DownloadDraft(preferences: Preferences())
        draft.link = "https://example.com/playlist"
        #expect(draft.request.engine == .http)
        draft.changesName = true
        draft.customName = "show.m3u8"
        #expect(draft.request.engine == .ytDlp)
    }

    @Test func editingKeepsTheEngine() {
        let request = DownloadRequest(link: "https://s/v", customFileName: "t_video.mp4", folder: "/d", connections: 1, engine: .ytDlp)
        let summary = DownloadSummary(
            gid: GID(rawValue: "aaaaaaaaaaaaaaaa")!, request: request, status: .stopped, category: "Single Downloads",
            fileName: "t_video.mp4", filePath: nil, totalBytes: nil, downloadedBytes: 0,
            firstTryDate: Date(), lastTryDate: Date()
        )
        #expect(DownloadDraft(editing: summary, secrets: DownloadSecrets()).request.engine == .ytDlp)
    }
}

@Suite("Helper updates")
struct HelperInstallationTests {
    private struct Fixture {
        let root: URL
        var bundled: URL { root.appending(path: "bundle") }
        var support: URL { root.appending(path: "support") }
        var logPath: String { root.appending(path: "log.txt").path }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        }

        func installation() -> HelperInstallation {
            HelperInstallation(bundledFolder: bundled, supportFolder: support)
        }

        /// A stand-in yt-dlp. The update replaces it with `updated`, if there is one.
        func writeYtDlp(in folder: URL, version: String, updated: String? = nil, updateFails: Bool = false) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appending(path: "yt-dlp").path
            var update = updated.map { "printf '%s' '\($0)' > \"$0\"; chmod 700 \"$0\"" } ?? ":"
            if updateFails { update = "exit 1" }
            let text = """
            #!/bin/sh
            echo "$0 $*" >> "\(logPath)"
            case "$*" in
              *--update*) \(update) ;;
              *--version*) echo \(version) ;;
            esac
            """
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }

        var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
        var copyPath: String { support.appending(path: "yt-dlp").path }
        var bundledPath: String { bundled.appending(path: "yt-dlp").path }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nothingBundledMeansNoHelpers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let paths = fixture.installation().paths
        #expect(paths.ytDlp == nil)
        #expect(paths.ffmpeg == nil)
        #expect(paths.deno == nil)
    }

    @Test func untilThereIsACopyTheBundledOneIsUsed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26")
        try "x".write(to: fixture.bundled.appending(path: "ffmpeg"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.bundled.appending(path: "ffmpeg").path)

        let paths = fixture.installation().paths
        #expect(paths.ytDlp == fixture.bundledPath)
        #expect(paths.ffmpeg == fixture.bundled.appending(path: "ffmpeg").path)
    }

    @Test func theFirstCheckMakesACopyAndUpdatesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26")

        let checked = await fixture.installation().updateIfDue(lastCheck: nil, now: now)

        #expect(checked == now)
        #expect(FileManager.default.isExecutableFile(atPath: fixture.copyPath))
        #expect(fixture.installation().paths.ytDlp == fixture.copyPath)
        #expect(fixture.log.contains("\(fixture.copyPath) --ignore-config --update"))
    }

    @Test func aRecentCheckMeansNoCheck() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26")

        let recent = now.addingTimeInterval(-3_600)
        let checked = await fixture.installation().updateIfDue(lastCheck: recent, now: now)

        #expect(checked == recent)
        #expect(fixture.log.isEmpty)
    }

    @Test func aDayLaterItChecksAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26")

        let checked = await fixture.installation().updateIfDue(lastCheck: now.addingTimeInterval(-86_401), now: now)

        #expect(checked == now)
        #expect(fixture.log.contains("--update"))
    }

    /// With no network, the copy that works is kept, and it tries again the next day.
    @Test func aFailedUpdateKeepsWhatWorks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26", updateFails: true)

        _ = await fixture.installation().updateIfDue(lastCheck: nil, now: now)

        #expect(fixture.installation().paths.ytDlp == fixture.copyPath)
    }

    @Test func anUpdateThatDoesntRunIsThrownAway() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26", updated: "broken")

        _ = await fixture.installation().updateIfDue(lastCheck: nil, now: now)

        #expect(!FileManager.default.fileExists(atPath: fixture.copyPath))
        #expect(fixture.installation().paths.ytDlp == fixture.bundledPath)
    }

    /// A new version of the app can bring a newer yt-dlp than the copy.
    @Test func aNewerBundledCopyReplacesTheOldOne() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.11.01")
        try fixture.writeYtDlp(in: fixture.support, version: "2026.10.26")

        _ = await fixture.installation().updateIfDue(lastCheck: nil, now: now)

        let copied = try String(contentsOfFile: fixture.copyPath, encoding: .utf8)
        #expect(copied.contains("echo 2026.11.01"))
    }

    @Test func aNewerCopyIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeYtDlp(in: fixture.bundled, version: "2026.10.26")
        try fixture.writeYtDlp(in: fixture.support, version: "2026.11.01")

        _ = await fixture.installation().updateIfDue(lastCheck: nil, now: now)

        let copied = try String(contentsOfFile: fixture.copyPath, encoding: .utf8)
        #expect(copied.contains("echo 2026.11.01"))
    }
}
