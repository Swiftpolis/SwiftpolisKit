import Foundation
import SwiftpolisDomain
import Testing

@Suite("Video rules")
struct VideoRulesTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=abc",
        "https://www.aparat.com/v/abc",
        "https://vimeo.com/123",
        "https://www.dailymotion.com/video/x8",
        "https://soundcloud.com/someone/track",
    ])
    func videoFinderTakesLinksToItsSites(link: String) {
        #expect(VideoSites.isSupported(link))
    }

    @Test(arguments: [
        "https://www.youtube.com/",
        "https://example.com/file.zip",
        "http://soundcloud.com/someone/track",
    ])
    func videoFinderLeavesOtherLinks(link: String) {
        #expect(!VideoSites.isSupported(link))
    }

    @Test func aNameEndingInM3u8GoesToYtDlp() {
        #expect(DownloadEngineKind(customFileName: "stream.M3U8") == .ytDlp)
        #expect(DownloadEngineKind(customFileName: "stream.mp4") == .http)
        #expect(DownloadEngineKind(customFileName: nil) == .http)
    }

    @Test func aPairKnowsItsMembers() {
        let video = GID(rawValue: "aaaaaaaaaaaaaaaa")!
        let audio = GID(rawValue: "bbbbbbbbbbbbbbbb")!
        let pair = VideoPair(videoGID: video, audioGID: audio, muxingStatus: .notStarted)
        #expect(pair.contains(video))
        #expect(pair.contains(audio))
        #expect(pair.partner(of: video) == audio)
        #expect(pair.partner(of: audio) == video)
        #expect(!pair.contains(GID(rawValue: "cccccccccccccccc")!))
    }

    @Test func yrDlpDownloadsCannotPause() {
        let actions = DownloadActions(status: .downloading, category: CategoryKind.singleDownloadsName, engine: .ytDlp)
        #expect(!actions.canPause)
        #expect(actions.canStop)
        #expect(actions.canShowProgress)
    }

    @Test func httpDownloadsStillPause() {
        let actions = DownloadActions(status: .downloading, category: CategoryKind.singleDownloadsName)
        #expect(actions.canPause)
    }
}

@Suite("Running times")
struct RunningTimeTests {
    @Test func aRunningTimeReadsAsAClock() {
        #expect(DurationFormat.clock(seconds: 73) == "1:13")
        #expect(DurationFormat.clock(seconds: 5) == "0:05")
        #expect(DurationFormat.clock(seconds: 3_723) == "1:02:03")
    }
}
