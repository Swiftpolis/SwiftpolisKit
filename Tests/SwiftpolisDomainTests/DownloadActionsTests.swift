import Testing
import SwiftpolisDomain

/// The table in Persepolis's `checkSelectedRow`.
@Suite("Download actions")
struct DownloadActionsTests {
    private let single = "Single Downloads"

    @Test("a Single Download offers what its status allows", arguments: [
        //                 resume pause  stop   props  prog   open
        (DownloadStatus.scheduled, false, false, true, false, true, false),
        (.stopped, true, false, false, true, false, false),
        (.error, true, false, false, true, false, false),
        (.downloading, false, true, true, false, true, false),
        (.waiting, false, false, true, false, true, false),
        (.complete, false, false, false, true, false, true),
        (.paused, true, false, true, false, true, false),
        (.creatingDownloadFile, false, false, false, false, false, false),
    ])
    func singleDownload(
        status: DownloadStatus,
        resume: Bool,
        pause: Bool,
        stop: Bool,
        properties: Bool,
        progress: Bool,
        files: Bool
    ) {
        let actions = DownloadActions(status: status, category: single)
        #expect(actions.canResume == resume)
        #expect(actions.canPause == pause)
        #expect(actions.canStop == stop)
        #expect(actions.canEditProperties == properties)
        #expect(actions.canShowProgress == progress)
        #expect(actions.canOpenFile == files)
        #expect(actions.canOpenFolder == files)
        #expect(actions.canMoveFile == files)
    }

    @Test("a Download in a Queue offers controls, which then explain themselves", arguments: [
        (DownloadStatus.complete, true, true),
        (.stopped, true, false),
        (.error, true, false),
        (.downloading, false, false),
        (.waiting, false, false),
        (.paused, false, false),
        (.scheduled, false, false),
    ])
    func queuedDownload(status: DownloadStatus, properties: Bool, files: Bool) {
        let actions = DownloadActions(status: status, category: "Movies")
        #expect(actions.canResume && actions.canPause && actions.canStop)
        #expect(!actions.canShowProgress)
        #expect(actions.canEditProperties == properties)
        #expect(actions.canOpenFile == files)
    }

    @Test("only finished Downloads can be removed from the list", arguments: [
        (DownloadStatus.complete, true),
        (.stopped, true),
        (.error, true),
        (.downloading, false),
        (.waiting, false),
        (.paused, false),
        (.scheduled, false),
        (.creatingDownloadFile, false),
    ])
    func removal(status: DownloadStatus, removable: Bool) {
        #expect(status.canBeRemoved == removable)
    }
}

@Suite("Sorting")
struct DownloadSortingTests {
    private func item(
        _ name: String?,
        status: DownloadStatus = .stopped,
        size: Int64? = nil,
        first: Double = 0,
        last: Double = 0
    ) -> DownloadSortFields {
        DownloadSortFields(
            fileName: name,
            status: status,
            totalBytes: size,
            firstTry: .init(timeIntervalSince1970: first),
            lastTry: .init(timeIntervalSince1970: last)
        )
    }

    @Test("by name, A to Z")
    func byName() {
        let order = DownloadSortKey.name.sorted([item("b"), item("a"), item("c")])
        #expect(order.map(\.fileName) == ["a", "b", "c"])
    }

    @Test("by size, largest first, with unknown sizes last")
    func bySize() {
        let order = DownloadSortKey.size.sorted([item("small", size: 1), item("unknown"), item("big", size: 9)])
        #expect(order.map(\.fileName) == ["big", "small", "unknown"])
    }

    @Test("by status, in Persepolis's order")
    func byStatus() {
        let order = DownloadSortKey.status.sorted([
            item("other", status: .paused),
            item("waiting", status: .waiting),
            item("downloading", status: .downloading),
            item("error", status: .error),
            item("stopped", status: .stopped),
            item("complete", status: .complete),
        ])
        #expect(order.map(\.fileName) == ["complete", "stopped", "error", "downloading", "waiting", "other"])
    }

    @Test("by dates, newest first")
    func byDates() {
        let items = [item("old", first: 1, last: 5), item("new", first: 9, last: 2)]
        #expect(DownloadSortKey.firstTry.sorted(items).map(\.fileName) == ["new", "old"])
        #expect(DownloadSortKey.lastTry.sorted(items).map(\.fileName) == ["old", "new"])
    }
}
