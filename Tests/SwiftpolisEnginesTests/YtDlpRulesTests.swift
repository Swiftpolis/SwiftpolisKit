import Foundation
import SwiftpolisDomain
import Testing
@testable import SwiftpolisEngines

@Suite("yt-dlp progress lines")
struct YtDlpProgressTests {
    // These two are trimmed from a real download of an HLS stream.
    @Test func aFragmentedStreamReportsAnEstimate() throws {
        let line = """
        {"status": "downloading", "downloaded_bytes": 1024, "fragment_index": 3, "fragment_count": 24, \
        "filename": "dl/dm.mp4", "tmpfilename": "dl/dm.mp4.part", "elapsed": 0, \
        "total_bytes_estimate": 4642848.0, "speed": 1894.5, "eta": null}
        """
        let progress = try #require(YtDlpProgress(line: line))
        #expect(progress.status == .downloading)
        #expect(progress.downloadedBytes == 1024)
        #expect(progress.totalBytes == 4642848)
        #expect(progress.bytesPerSecond == 1894.5)
        #expect(progress.secondsRemaining == nil)
        #expect(progress.fragments == "3/24")
    }

    @Test func aFinishedLineCarriesTheTrueSize() throws {
        let line = """
        {"downloaded_bytes": 4435860, "total_bytes": 4435860, "filename": "dl/dm.mp4", "status": "finished"}
        """
        let progress = try #require(YtDlpProgress(line: line))
        #expect(progress.status == .finished)
        #expect(progress.totalBytes == 4435860)
        #expect(progress.fragments == nil)
    }

    @Test func aTrueSizeWinsOverAnEstimate() throws {
        let line = #"{"status": "downloading", "total_bytes": 10, "total_bytes_estimate": 99.0, "eta": 7}"#
        let progress = try #require(YtDlpProgress(line: line))
        #expect(progress.totalBytes == 10)
        #expect(progress.secondsRemaining == 7)
    }

    @Test(arguments: ["", "[download] 10%", "{not json", "[1, 2]"])
    func otherLinesAreIgnored(line: String) {
        #expect(YtDlpProgress(line: line) == nil)
    }
}

@Suite("yt-dlp options")
struct YtDlpConfigurationTests {
    private func request(_ change: (inout DownloadRequest) -> Void = { _ in }) -> DownloadRequest {
        var request = DownloadRequest(link: "https://cdn.example/v.mp4", folder: "/tmp", connections: 1)
        request.engine = .ytDlp
        change(&request)
        return request
    }

    private func options(
        _ request: DownloadRequest,
        secrets: DownloadSecrets = DownloadSecrets(),
        settings: EngineSettings = EngineSettings()
    ) -> [String] {
        YtDlpConfiguration(
            link: request.link,
            outputPath: "/tmp/v.mp4",
            request: request,
            secrets: secrets,
            settings: settings,
            cookieFile: nil,
            ffmpegPath: "/helpers/ffmpeg"
        ).arguments
    }

    private func value(of option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).map { arguments[$0 + 1] }
    }

    @Test func theFixedOptionsAreThere() {
        var settings = EngineSettings()
        settings.maxTries = 7
        settings.timeout = 12
        let arguments = options(request(), settings: settings)

        #expect(value(of: "--retries", in: arguments) == "7")
        #expect(value(of: "--socket-timeout", in: arguments) == "12")
        #expect(value(of: "--ffmpeg-location", in: arguments) == "/helpers/ffmpeg")
        #expect(value(of: "--progress-template", in: arguments) == "download:%(progress)j")
        #expect(value(of: "--output", in: arguments) == "/tmp/v.mp4")
        #expect(arguments.contains("--no-playlist"))
        #expect(arguments.contains("--continue"))
        #expect(arguments.contains("--newline"))
    }

    /// A link is last and after `--`, so a link that starts with a dash can't be taken as an option.
    @Test func onlyTheLinkIsOnTheCommandLine() {
        #expect(YtDlpConfiguration.commandLine(configFile: "/private/c.conf", link: "-x") == [
            "--ignore-config", "--config-locations", "/private/c.conf", "--", "-x",
        ])
        #expect(!options(request()).contains("https://cdn.example/v.mp4"))
    }

    /// D31: Persepolis misnames these, so yt-dlp never receives them.
    @Test func userAgentRefererAndHeadersUseTheRealOptions() {
        let arguments = options(request {
            $0.userAgent = "UA"
            $0.referer = "https://page.example/"
            $0.headers = "Accept: */*\nX-One: 1"
        })
        #expect(value(of: "--user-agent", in: arguments) == "UA")
        #expect(value(of: "--referer", in: arguments) == "https://page.example/")

        let headers = arguments.indices.filter { arguments[$0] == "--add-headers" }.map { arguments[$0 + 1] }
        #expect(Set(headers) == ["Accept:*/*", "X-One:1"])
    }

    @Test func withoutAUserAgentYtDlpUsesItsOwn() {
        #expect(!options(request()).contains("--user-agent"))
    }

    @Test func certificateChecksFollowThePreference() {
        var settings = EngineSettings()
        #expect(!options(request(), settings: settings).contains("--no-check-certificates"))
        settings.verifiesCertificates = false
        #expect(options(request(), settings: settings).contains("--no-check-certificates"))
    }

    @Test func aProxyIsOneAddressWithItsPasswordEncoded() {
        let arguments = options(
            request { $0.proxy = ProxySettings(kind: .socks5, host: "10.0.0.1", port: 1080, user: "me@home") },
            secrets: DownloadSecrets(proxyPassword: "p:ss/word")
        )
        #expect(value(of: "--proxy", in: arguments) == "socks5://me%40home:p%3Ass%2Fword@10.0.0.1:1080")
    }

    @Test func aProxyWithoutALoginHasNone() {
        let arguments = options(request { $0.proxy = ProxySettings(kind: .http, host: "h", port: 8080) })
        #expect(value(of: "--proxy", in: arguments) == "http://h:8080")
    }

    @Test func aSiteLoginIsPassedOn() {
        let arguments = options(request { $0.httpUser = "me" }, secrets: DownloadSecrets(httpPassword: "pw"))
        #expect(value(of: "--username", in: arguments) == "me")
        #expect(value(of: "--password", in: arguments) == "pw")
    }

    @Test func aPercentInTheFileNameIsNotATemplate() {
        #expect(YtDlpConfiguration.outputTemplate(for: "/tmp/100%(x)s.mp4") == "/tmp/100%%(x)s.mp4")
    }

    /// The file holds passwords, because the command line is visible to every process on the Mac.
    @Test func theFileQuotesEverythingForItsParser() {
        let text = YtDlpConfiguration.fileText(for: ["--password", #"a"b\c #d"#, "--no-playlist"])
        #expect(text == #""--password" "a\"b\\c #d" "--no-playlist""# + "\n")
    }

    @Test func browserCookiesBecomeACookieFileForTheLinksSite() {
        let text = YtDlpConfiguration.netscapeCookies(
            header: "a=1; b=two=2",
            link: "https://www.youtube.com/watch?v=x"
        )
        #expect(text == """
        # Netscape HTTP Cookie File
        .youtube.com\tTRUE\t/\tFALSE\t0\ta\t1
        .youtube.com\tTRUE\t/\tFALSE\t0\tb\ttwo=2

        """)
    }
}

@Suite("Muxed file names")
struct MuxPlanTests {
    @Test func theStreamMarkerIsDropped() {
        #expect(MuxPlan.finalName(videoPath: "/d/Some title_video.mp4") == "Some title.mp4")
    }

    @Test func webmBecomesMkv() {
        #expect(MuxPlan.finalName(videoPath: "/d/Some title_video.webm") == "Some title.mkv")
    }

    @Test func aNameWithoutTheMarkerIsKept() {
        #expect(MuxPlan.finalName(videoPath: "/d/other.mp4") == "other.mp4")
    }

    @Test func aPercentEncodedNameIsReadable() {
        #expect(MuxPlan.finalName(videoPath: "/d/a%20b_video.mp4") == "a b.mp4")
    }

    @Test func ffmpegGetsPersepolisArguments() {
        #expect(MuxPlan.arguments(video: "/v.mp4", audio: "/a.m4a", output: "/o.mp4") == [
            "-i", "/v.mp4", "-i", "/a.m4a", "-c", "copy", "-shortest", "-map", "0:v:0", "-map", "1:a:0",
            "-loglevel", "error", "-strict", "-2", "/o.mp4",
        ])
    }
}

@Suite("Video formats")
struct VideoFormatsTests {
    private func formats(_ json: String) throws -> VideoFormats {
        try VideoFormats(json: Data(json.utf8))
    }

    private let separate = """
    {"title": "A title that is longer than twenty", "duration": 73, "thumbnail": "https://i.example/t.jpg",
     "formats": [
      {"format_id": "sb0", "url": "https://i.example/sb", "ext": "mhtml", "acodec": "none", "vcodec": "none",
       "format_note": "storyboard"},
      {"format_id": "18", "url": "https://s/18", "ext": "mp4", "acodec": "mp4a", "vcodec": "avc1", "height": 360,
       "protocol": "https", "filesize": 1048576},
      {"format_id": "140", "url": "https://s/140", "ext": "m4a", "acodec": "mp4a", "vcodec": "none", "abr": 128.5,
       "protocol": "https", "filesize": 2097152},
      {"format_id": "251", "url": "https://s/251", "ext": "webm", "acodec": "opus", "vcodec": "none", "abr": 160,
       "protocol": "https", "filesize_approx": 3145728},
      {"format_id": "136", "url": "https://s/136", "ext": "mp4", "acodec": "none", "vcodec": "avc1", "height": 720,
       "protocol": "https", "filesize": 5242880},
      {"format_id": "137", "url": "https://s/137.m3u8?x=1", "ext": "mp4", "acodec": "none", "vcodec": "avc1",
       "height": 1080, "protocol": "m3u8_native",
       "http_headers": {"User-Agent": "UA1", "Referer": "https://r.example/", "Accept": "*/*"}}
     ]}
    """

    @Test func formatsAreSorted() throws {
        let found = try formats(separate)
        #expect(found.combined.map(\.id) == ["18"])
        #expect(found.audioOnly.map(\.id) == ["140", "251"])
        #expect(found.videoOnly.map(\.id) == ["136", "137"])
    }

    @Test func labelsReadAsInPersepolis() throws {
        let found = try formats(separate)
        #expect(found.combined[0].label == "360p .mp4 1 MiB")
        #expect(found.audioOnly[0].label == "128.5kbps .m4a 2 MiB")
        #expect(found.audioOnly[1].label == "160kbps .webm 3 MiB")
        #expect(found.videoOnly[0].label == "720p .mp4 5 MiB")
        #expect(found.videoOnly[1].label == "1080p .mp4 m3u8")
    }

    @Test func theCombinedListMarksItsEnds() throws {
        let found = try formats("""
        {"formats": [
          {"format_id": "a", "url": "https://s/a", "ext": "mp4", "acodec": "x", "vcodec": "y", "height": 288},
          {"format_id": "b", "url": "https://s/b", "ext": "mp4", "acodec": "x", "vcodec": "y", "height": 480},
          {"format_id": "c", "url": "https://s/c", "ext": "mp4", "acodec": "x", "vcodec": "y", "height": 1080}
        ]}
        """)
        #expect(found.combined.map(\.label) == [
            "Worst quality: 288p .mp4", "480p .mp4", "Best quality: 1080p .mp4",
        ])
    }

    @Test func aMissingAudioRateOrHeightIsLeftOut() throws {
        let found = try formats("""
        {"formats": [
          {"format_id": "a", "url": "https://s/a", "ext": "m4a", "acodec": "x", "vcodec": "none"},
          {"format_id": "b", "url": "https://s/b", "ext": "mp4", "acodec": "none", "vcodec": "y"}
        ]}
        """)
        #expect(found.audioOnly[0].label == ".m4a")
        #expect(found.videoOnly[0].label == ".mp4")
    }

    @Test func aPlainStreamIsDirectAndAPlaylistIsNot() throws {
        let found = try formats(separate)
        #expect(found.combined[0].isDirect)
        #expect(!found.videoOnly[1].isDirect)
    }

    @Test func aDashManifestIsNotDirect() throws {
        let found = try formats("""
        {"formats": [{"format_id": "d", "url": "https://s/m.mpd", "ext": "mp4", "acodec": "x", "vcodec": "y",
                      "protocol": "http_dash_segments"}]}
        """)
        #expect(!found.combined[0].isDirect)
    }

    @Test func aTitleBecomesAShortSafeName() throws {
        #expect(try formats(separate).suggestedName == "A title that is long")
        let slash = try formats(#"{"title": "AC/DC: live", "formats": []}"#)
        #expect(slash.suggestedName == "AC_DC_ live")
        #expect(try formats(#"{"formats": []}"#).suggestedName == "Video finder")
    }

    @Test func aTitleEndingInASpaceAfterCuttingIsTrimmed() throws {
        let found = try formats(#"{"title": "Twenty characters ok then more", "formats": []}"#)
        #expect(found.suggestedName == "Twenty characters ok")
        let spaced = try formats(#"{"title": "Nineteen characters more", "formats": []}"#)
        #expect(spaced.suggestedName == "Nineteen characters")
    }

    @Test func theRestIsRead() throws {
        let found = try formats(separate)
        #expect(found.title == "A title that is longer than twenty")
        #expect(found.durationSeconds == 73)
        #expect(found.thumbnail == "https://i.example/t.jpg")
    }

    @Test func theLastFormatsHeadersAreKept() throws {
        let found = try formats(separate)
        #expect(found.userAgent == "UA1")
        #expect(found.referer == "https://r.example/")
        #expect(found.headers == "Accept: */*")
    }

    @Test func aPlaylistUsesItsFirstEntry() throws {
        let found = try formats("""
        {"entries": [{"title": "First", "formats": [
          {"format_id": "a", "url": "https://s/a", "ext": "mp4", "acodec": "x", "vcodec": "y"}]}]}
        """)
        #expect(found.combined.map(\.id) == ["a"])
    }

    @Test func aSingleFormatResultIsItsOwnList() throws {
        let found = try formats("""
        {"title": "Solo", "format": "best", "format_id": "s", "url": "https://s/s", "ext": "mp3",
         "acodec": "mp3", "vcodec": "none", "abr": 128}
        """)
        #expect(found.audioOnly.map(\.id) == ["s"])
    }
}
