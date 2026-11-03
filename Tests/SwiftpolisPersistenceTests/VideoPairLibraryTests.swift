import Foundation
import SwiftData
import SwiftpolisDomain
import Testing
@testable import SwiftpolisPersistence

@Suite("Video pairs in the library")
struct VideoPairLibraryTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let single = CategoryKind.singleDownloadsName

    private func makeRepository() async throws -> LibraryRepository {
        let repository = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await repository.prepareForLaunch()
        return repository
    }

    private func stream(_ name: String) -> DownloadRequest {
        DownloadRequest(
            link: "https://s.example/\(name)",
            customFileName: name,
            folder: "/Downloads",
            connections: 1,
            engine: .ytDlp
        )
    }

    private func addPair(to repository: LibraryRepository, category: String? = nil) async throws -> VideoPair {
        try await repository.addVideoPair(
            video: stream("t_video.mp4"),
            audio: stream("t_audio.m4a"),
            to: category ?? single,
            videoStatus: .waiting,
            at: date
        )
    }

    @Test func aDownloadRemembersItsEngine() async throws {
        let repository = try await makeRepository()
        let gid = try await repository.addDownload(stream("a.mp4"), to: single, status: .stopped, at: date)
        #expect(try await repository.download(gid)?.request.engine == .ytDlp)

        var plain = stream("a.mp4")
        plain.engine = .http
        try await repository.updateRequest(plain, for: gid)
        #expect(try await repository.download(gid)?.request.engine == .http)
    }

    @Test func aPairAddsBothStreamsVideoFirst() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)

        #expect(pair.muxingStatus == .notStarted)
        #expect(try await repository.download(pair.videoGID)?.status == .waiting)
        #expect(try await repository.download(pair.audioGID)?.status == .stopped)
        // Lists show the newest first, so the audio stream, added second, is on top.
        #expect(try await repository.downloads(in: single).map(\.gid) == [pair.audioGID, pair.videoGID])
    }

    @Test func eitherStreamFindsItsPair() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)
        let other = try await repository.addDownload(stream("x.mp4"), to: single, status: .stopped, at: date)

        #expect(try await repository.videoPair(containing: pair.videoGID) == pair)
        #expect(try await repository.videoPair(containing: pair.audioGID) == pair)
        #expect(try await repository.videoPair(containing: other) == nil)
        #expect(try await repository.videoPairs() == [pair])
    }

    @Test func theMuxingStatusIsSaved() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)
        try await repository.setMuxingStatus(.error, for: pair)
        #expect(try await repository.videoPair(containing: pair.videoGID)?.muxingStatus == .error)
    }

    @Test func finishingLeavesOneCompleteDownload() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)

        try await repository.finishVideoPair(pair, fileName: "t.mp4", filePath: "/Downloads/t.mp4", bytes: 99)

        #expect(try await repository.download(pair.audioGID) == nil)
        #expect(try await repository.videoPairs().isEmpty)
        let video = try #require(try await repository.download(pair.videoGID))
        #expect(video.status == .complete)
        #expect(video.fileName == "t.mp4")
        #expect(video.filePath == "/Downloads/t.mp4")
        #expect(video.totalBytes == 99)
        #expect(video.downloadedBytes == 99)
    }

    @Test func removingAStreamEndsThePair() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)
        try await repository.removeDownloads([pair.videoGID, pair.audioGID])
        #expect(try await repository.videoPairs().isEmpty)
    }

    @Test func clearingTheListEndsPairs() async throws {
        let repository = try await makeRepository()
        _ = try await addPair(to: repository)
        try await repository.clearList()
        #expect(try await repository.videoPairs().isEmpty)
    }

    @Test func removingAQueueEndsItsPairsOnly() async throws {
        let repository = try await makeRepository()
        try await repository.createQueue(named: "Evening")
        _ = try await addPair(to: repository, category: "Evening")
        let kept = try await addPair(to: repository)

        try await repository.removeQueue(named: "Evening")
        #expect(try await repository.videoPairs() == [kept])
    }

    /// Nothing is muxing just after launch, so an interrupted one has to be offered again.
    @Test func muxingInterruptedByQuittingIsAnError() async throws {
        let repository = try await makeRepository()
        let pair = try await addPair(to: repository)
        try await repository.setMuxingStatus(.muxing, for: pair)

        try await repository.prepareForLaunch()

        #expect(try await repository.videoPair(containing: pair.videoGID)?.muxingStatus == .error)
    }

    /// A library from before pairs existed has to open with everything intact.
    @Test func aLibraryFromTheFirstVersionOpens() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library.store")

        do {
            let schema = Schema(versionedSchema: LibrarySchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let category = LibrarySchemaV1.CategoryRecord(name: single, sidePanelPosition: 0)
            context.insert(category)
            let download = LibrarySchemaV1.DownloadRecord(
                gid: "aaaaaaaaaaaaaaaa", categoryPosition: 0, allDownloadsPosition: 0, statusRawValue: "complete",
                date: date, link: "https://example.com/a.zip", customFileName: "a.zip", folder: "/Downloads",
                connections: 4, speedDial: 10, startTimeMinutes: nil, endTimeMinutes: nil, proxyKindRawValue: nil,
                proxyHost: nil, proxyPort: nil, proxyUser: nil, httpUser: nil, referer: nil, userAgent: nil,
                headers: nil, cookieFilePath: nil, shutsDownAfterDownload: false
            )
            context.insert(download)
            download.category = category
            try context.save()
        }

        let repository = LibraryRepository(modelContainer: try LibraryStore.makeContainer(at: url))
        try await repository.prepareForLaunch()

        let found = try #require(try await repository.download(GID(rawValue: "aaaaaaaaaaaaaaaa")!))
        #expect(found.request.link == "https://example.com/a.zip")
        #expect(found.request.engine == .http)
        #expect(found.status == .complete)
        #expect(try await repository.videoPairs().isEmpty)
    }
}
