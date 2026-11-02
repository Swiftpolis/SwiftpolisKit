import Testing
import SwiftpolisDomain

@Suite("DownloadStatus")
struct DownloadStatusTests {
    @Test("reads every status string Persepolis stores", arguments: [
        ("waiting", DownloadStatus.waiting),
        ("scheduled", .scheduled),
        ("creating download file", .creatingDownloadFile),
        ("downloading", .downloading),
        ("paused", .paused),
        ("stopped", .stopped),
        ("error", .error),
        ("complete", .complete),
    ])
    func readsPersepolisStrings(raw: String, status: DownloadStatus) {
        #expect(DownloadStatus(rawValue: raw) == status)
    }

    @Test("only complete and error survive a launch", arguments: [
        (DownloadStatus.waiting, DownloadStatus.stopped),
        (.scheduled, .stopped),
        (.creatingDownloadFile, .stopped),
        (.downloading, .stopped),
        (.paused, .stopped),
        (.stopped, .stopped),
        (.error, .error),
        (.complete, .complete),
    ])
    func afterLaunch(status: DownloadStatus, expected: DownloadStatus) {
        #expect(status.afterLaunch == expected)
    }

    @Test("can change Category only when error, stopped or complete", arguments: [
        (DownloadStatus.waiting, false),
        (.scheduled, false),
        (.creatingDownloadFile, false),
        (.downloading, false),
        (.paused, false),
        (.stopped, true),
        (.error, true),
        (.complete, true),
    ])
    func canChangeCategory(status: DownloadStatus, expected: Bool) {
        #expect(status.canChangeCategory == expected)
    }
}
