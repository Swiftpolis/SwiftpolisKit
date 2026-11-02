import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisPersistence

@Suite("LibraryRepository")
struct LibraryRepositoryTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepository() async throws -> LibraryRepository {
        let repository = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await repository.prepareForLaunch()
        return repository
    }

    private func request(_ link: String) -> DownloadRequest {
        DownloadRequest(link: link, folder: "/Downloads", connections: 64)
    }

    // MARK: Categories

    @Test("a new library has the built-in Categories in order")
    func builtIns() async throws {
        let repository = try await makeRepository()
        let names = try await repository.categories().map(\.name)
        #expect(names == ["All Downloads", "Single Downloads", "Scheduled Downloads"])
    }

    @Test("preparing twice doesn't duplicate them")
    func preparingIsIdempotent() async throws {
        let repository = try await makeRepository()
        try await repository.prepareForLaunch()
        #expect(try await repository.categories().count == 3)
    }

    @Test("new Queues go after existing Categories")
    func createQueue() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Movies")
        try await repository.createQueue(named: "Music")

        let categories = try await repository.categories()
        #expect(categories.map(\.name).suffix(2) == ["Movies", "Music"])
        #expect(categories.last?.kind == .queue)
    }

    @Test("a Queue with a taken name is refused")
    func duplicateQueue() async throws {
        let repository = try await makeRepository()
        await #expect(throws: QueueNameError.alreadyExists) {
            try await repository.createQueue(named: "Scheduled Downloads")
        }
    }

    @Test("a new Queue starts with Persepolis's defaults")
    func queueDefaults() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Movies")

        let options = try #require(try await repository.categories().last?.options)
        #expect(options == QueueOptions())
        #expect(options.startTime == ClockTime(hour: 0, minute: 0))
        #expect(options.endTime == ClockTime(hour: 0, minute: 0))
        #expect(!options.startTimeEnabled && !options.endTimeEnabled)
        #expect(!options.isReversed && !options.shutsDownAfterDownload)
    }

    @Test("removing a Queue removes its Downloads from All Downloads too")
    func removeQueue() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Movies")
        _ = try await repository.addDownload(request("https://a"), to: "Movies", status: .stopped, at: date)
        let kept = try await repository.addDownload(request("https://b"), to: "Single Downloads", status: .stopped, at: date)

        try await repository.removeQueue(named: "Movies")

        #expect(try await repository.categories().map(\.name).contains("Movies") == false)
        #expect(try await repository.downloads(in: "All Downloads").map(\.gid) == [kept])
    }

    @Test("built-in Categories can't be removed", arguments: CategoryKind.builtInNames)
    func builtInsStay(name: String) async throws {
        let repository = try await makeRepository()
        await #expect(throws: LibraryError.categoryCannotBeRemoved(name)) {
            try await repository.removeQueue(named: name)
        }
    }

    // MARK: Downloads

    @Test("a new Download keeps what it was given")
    func addDownload() async throws {
        let repository = try await makeRepository()
        var request = request("https://example.com/file.zip")
        request.customFileName = "file.zip"
        request.startTime = ClockTime(hour: 2, minute: 0)
        request.endTime = ClockTime(hour: 6, minute: 0)
        request.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080, user: "me")
        request.httpUser = "site-user"
        request.referer = "https://example.com"
        request.userAgent = "Agent"
        request.headers = "X-A: 1"
        request.cookieFilePath = "/tmp/cookies.txt"
        request.speedDial = 7
        request.shutsDownAfterDownload = true

        let gid = try await repository.addDownload(request, to: "Single Downloads", status: .waiting, at: date)

        let download = try #require(try await repository.download(gid))
        #expect(download.request == request)
        #expect(download.status == .waiting)
        #expect(download.category == "Single Downloads")
        #expect(download.fileName == "file.zip")
        #expect(download.firstTryDate == date)
        #expect(download.lastTryDate == date)
        #expect(download.totalBytes == nil)
        #expect(download.downloadedBytes == 0)
    }

    @Test("adding to a Category that doesn't exist is refused")
    func missingCategory() async throws {
        let repository = try await makeRepository()
        await #expect(throws: LibraryError.categoryNotFound("Nope")) {
            _ = try await repository.addDownload(request("https://a"), to: "Nope", status: .stopped, at: date)
        }
    }

    @Test("nothing can be added directly to All Downloads")
    func notAddableToAll() async throws {
        let repository = try await makeRepository()
        await #expect(throws: LibraryError.categoryNotAddable("All Downloads")) {
            _ = try await repository.addDownload(request("https://a"), to: "All Downloads", status: .stopped, at: date)
        }
    }

    @Test("lists show the newest Download first")
    func newestFirst() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Movies")
        let first = try await repository.addDownload(request("https://1"), to: "Movies", status: .stopped, at: date)
        let single = try await repository.addDownload(request("https://2"), to: "Single Downloads", status: .stopped, at: date)
        let third = try await repository.addDownload(request("https://3"), to: "Movies", status: .stopped, at: date)

        #expect(try await repository.downloads(in: "Movies").map(\.gid) == [third, first])
        #expect(try await repository.downloads(in: "Single Downloads").map(\.gid) == [single])
        #expect(try await repository.downloads(in: "All Downloads").map(\.gid) == [third, single, first])
    }

    @Test("Persepolis's duplicate check finds a link added before")
    func duplicateLink() async throws {
        let repository = try await makeRepository()
        _ = try await repository.addDownload(request("https://a"), to: "Single Downloads", status: .stopped, at: date)

        #expect(try await repository.containsLink("https://a"))
        #expect(try await !repository.containsLink("https://b"))
    }

    @Test("saved progress is read back")
    func saveProgress() async throws {
        let repository = try await makeRepository()
        let gid = try await repository.addDownload(request("https://a"), to: "Single Downloads", status: .waiting, at: date)

        try await repository.saveProgress(
            DownloadProgress(status: .downloading, fileName: "a.bin", totalBytes: 100, downloadedBytes: 40),
            for: gid
        )

        let download = try #require(try await repository.download(gid))
        #expect(download.status == .downloading)
        #expect(download.fileName == "a.bin")
        #expect(download.totalBytes == 100)
        #expect(download.downloadedBytes == 40)
    }

    // MARK: Store

    @Test("a library on disk is still there, in order, after reopening")
    func survivesReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library.store")

        let older: GID
        let newer: GID
        do {
            let repository = LibraryRepository(modelContainer: try LibraryStore.makeContainer(at: url))
            try await repository.prepareForLaunch()
            try await repository.createQueue(named: "Movies")
            older = try await repository.addDownload(request("https://1"), to: "Movies", status: .stopped, at: date)
            newer = try await repository.addDownload(request("https://2"), to: "Movies", status: .stopped, at: date)
        }

        let reopened = LibraryRepository(modelContainer: try LibraryStore.makeContainer(at: url))
        try await reopened.prepareForLaunch()

        #expect(try await reopened.categories().map(\.name).last == "Movies")
        #expect(try await reopened.downloads(in: "Movies").map(\.gid) == [newer, older])
    }

    // MARK: Launch

    @Test("a launch resets statuses, schedules and Queue flags, as in Persepolis")
    func launchReset() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Movies")

        let scheduledTime = ClockTime(hour: 2, minute: 30)
        let endTime = ClockTime(hour: 6, minute: 15)
        var options = QueueOptions()
        options.startTimeEnabled = true
        options.startTime = scheduledTime!
        options.endTimeEnabled = true
        options.endTime = endTime!
        options.isReversed = true
        options.shutsDownAfterDownload = true
        try await repository.updateQueueOptions(options, named: "Movies")

        var scheduled = request("https://scheduled")
        scheduled.startTime = scheduledTime
        scheduled.endTime = endTime
        scheduled.shutsDownAfterDownload = true
        let active = try await repository.addDownload(scheduled, to: "Movies", status: .downloading, at: date)
        let failed = try await repository.addDownload(request("https://failed"), to: "Movies", status: .error, at: date)
        let done = try await repository.addDownload(request("https://done"), to: "Movies", status: .complete, at: date)

        try await repository.prepareForLaunch()

        let reset = try #require(try await repository.download(active))
        #expect(reset.status == .stopped)
        #expect(reset.request.startTime == nil)
        #expect(reset.request.endTime == nil)
        #expect(!reset.request.shutsDownAfterDownload)
        #expect(try await repository.download(failed)?.status == .error)
        #expect(try await repository.download(done)?.status == .complete)

        let queue = try #require(try await repository.categories().last)
        #expect(!queue.options.startTimeEnabled)
        #expect(!queue.options.endTimeEnabled)
        #expect(!queue.options.isReversed)
        #expect(!queue.options.shutsDownAfterDownload)
        // The clock values stay, so the panel still shows the last times used.
        #expect(queue.options.startTime == scheduledTime)
        #expect(queue.options.endTime == endTime)
    }
}
