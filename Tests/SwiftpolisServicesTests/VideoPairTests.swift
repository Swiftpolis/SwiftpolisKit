import Foundation
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisPersistence
import SwiftpolisServices
import SwiftpolisTestSupport
import Testing

private final class PairRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var engineList: [FakeEngine] = []
    private var results: [VideoPairResult] = []
    private var finished: [FinishedDownload] = []
    private var muxCalls: [(video: String, audio: String, folder: String)] = []
    private var muxResult: Result<VideoMuxer.Output, VideoMuxer.Failure>
    private var heldMuxes: [CheckedContinuation<Void, Never>] = []
    private var holdsMux = false
    private var active: Set<GID> = []
    private var queueOutcomes: [QueueOutcome] = []
    private var shutdowns = 0

    init() {
        muxResult = .success(VideoMuxer.Output(fileName: "t.mp4", path: "/final/t.mp4", bytes: 7))
    }

    var engines: [FakeEngine] { lock.withLock { engineList } }
    var pairResults: [VideoPairResult] { lock.withLock { results } }
    var finishedDownloads: [FinishedDownload] { lock.withLock { finished } }
    var muxCallCount: Int { lock.withLock { muxCalls.count } }
    var lastMux: (video: String, audio: String, folder: String)? { lock.withLock { muxCalls.last } }
    var activePairs: Set<GID> { lock.withLock { active } }
    var outcomes: [QueueOutcome] { lock.withLock { queueOutcomes } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func make(_ request: DownloadRequest, _ secrets: DownloadSecrets) -> any DownloadEngine {
        let engine = FakeEngine(request: request, secrets: secrets)
        lock.withLock { engineList.append(engine) }
        return engine
    }

    func recordShutdown() { lock.withLock { shutdowns += 1 } }

    func setMuxResult(_ result: Result<VideoMuxer.Output, VideoMuxer.Failure>) {
        lock.withLock { muxResult = result }
    }

    func holdMuxes() { lock.withLock { holdsMux = true } }

    func releaseMuxes() {
        let held = lock.withLock {
            holdsMux = false
            defer { heldMuxes = [] }
            return heldMuxes
        }
        for continuation in held { continuation.resume() }
    }

    func mux(video: String, audio: String, folder: String) async -> Result<VideoMuxer.Output, VideoMuxer.Failure> {
        lock.withLock { muxCalls.append((video, audio, folder)) }
        await withCheckedContinuation { continuation in
            let isHeld = lock.withLock {
                if holdsMux { heldMuxes.append(continuation) }
                return holdsMux
            }
            if !isHeld { continuation.resume() }
        }
        return lock.withLock { muxResult }
    }

    func listen(to events: AsyncStream<DownloadEvent>) {
        Task {
            for await event in events {
                lock.withLock {
                    switch event {
                    case .videoPairFinished(let result): results.append(result)
                    case .finished(let download): finished.append(download)
                    case .videoPairsChanged(let pairs): active = pairs
                    case .queueFinished(_, let outcome): queueOutcomes.append(outcome)
                    default: break
                    }
                }
            }
        }
    }
}

private func eventually(
    timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private struct PairFixture {
    let library: LibraryRepository
    let clock = ManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let recorder = PairRecorder()
    let secrets = InMemorySecretStore()
    let coordinator: DownloadCoordinator
    let folder: String
    let single = CategoryKind.singleDownloadsName
    let queue = "Scheduled Downloads"

    init() async throws {
        library = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await library.prepareForLaunch()
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let recorder = self.recorder
        coordinator = DownloadCoordinator(
            library: library,
            secrets: secrets,
            clock: clock,
            tick: .milliseconds(2),
            shutDown: { recorder.recordShutdown() },
            makeEngine: { recorder.make($0, $1) },
            spider: { _, _ in Spider.Findings() },
            mux: { await recorder.mux(video: $0, audio: $1, folder: $2) }
        )
        recorder.listen(to: coordinator.events)
    }

    func stream(_ name: String) -> DownloadRequest {
        DownloadRequest(link: "https://s/\(name)", customFileName: name, folder: folder, connections: 1, engine: .ytDlp)
    }

    func add(to category: String? = nil, startNow: Bool = true) async throws -> VideoPair {
        try await coordinator.addVideoPair(
            video: stream("t_video.mp4"),
            audio: stream("t_audio.m4a"),
            secrets: DownloadSecrets(),
            to: category ?? single,
            startNow: startNow
        )
    }

    func path(_ name: String) -> String { folder + "/" + name }

    /// Waits for the given engine to run, then ends it. A complete one leaves a real file.
    func finish(engine number: Int, as status: DownloadStatus = .complete) async throws {
        await eventually {
            recorder.engines.count >= number && recorder.engines[number - 1].recordedCalls.contains("run")
        }
        let engine = recorder.engines[number - 1]
        let name = engine.request.customFileName ?? "file"
        if status == .complete {
            try "data".write(toFile: path(name), atomically: true, encoding: .utf8)
        }
        engine.end(status: status) {
            $0.fileName = name
            if status == .complete { $0.filePath = path(name) }
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: folder) }
}

@Suite("Video pairs: running")
struct VideoPairRunTests {
    @Test func videoThenAudioThenMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()

        try await fixture.finish(engine: 1)
        #expect(fixture.recorder.engines[0].request.customFileName == "t_video.mp4")
        #expect(fixture.recorder.muxCallCount == 0)

        try await fixture.finish(engine: 2)
        #expect(fixture.recorder.engines[1].request.customFileName == "t_audio.m4a")

        await eventually { fixture.recorder.pairResults.count == 1 }
        let mux = try #require(fixture.recorder.lastMux)
        #expect(mux.video == fixture.path("t_video.mp4"))
        #expect(mux.audio == fixture.path("t_audio.m4a"))
        #expect(mux.folder == fixture.folder)

        let result = fixture.recorder.pairResults[0]
        #expect(result.videoGID == pair.videoGID)
        #expect(result.outcome == .complete(fileName: "t.mp4", filePath: "/final/t.mp4"))

        // One complete Download is left, and the streams are gone.
        #expect(try await fixture.library.download(pair.audioGID) == nil)
        let video = try #require(try await fixture.library.download(pair.videoGID))
        #expect(video.status == .complete)
        #expect(video.filePath == "/final/t.mp4")
        #expect(video.totalBytes == 7)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("t_video.mp4")))
        #expect(!FileManager.default.fileExists(atPath: fixture.path("t_audio.m4a")))
        #expect(try await fixture.library.videoPairs().isEmpty)
    }

    @Test func aStartTimeBelongsToTheVideoOnly() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        var audio = fixture.stream("t_audio.m4a")
        audio.startTime = ClockTime(hour: 3, minute: 0)
        audio.endTime = ClockTime(hour: 23, minute: 59)
        let pair = try await fixture.coordinator.addVideoPair(
            video: fixture.stream("t_video.mp4"),
            audio: audio,
            secrets: DownloadSecrets(),
            to: fixture.single,
            startNow: true
        )

        try await fixture.finish(engine: 1)
        await eventually { fixture.recorder.engines.count == 2 }
        #expect(fixture.recorder.engines[1].request.startTime == nil)
        #expect(fixture.recorder.engines[1].request.endTime == ClockTime(hour: 23, minute: 59))
        _ = pair
    }

    @Test func stoppingEndsThePairWithoutMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        try await fixture.coordinator.stop(pair.audioGID)
        #expect(fixture.recorder.engines[0].recordedCalls.contains("stop"))
        fixture.recorder.engines[0].end(status: .stopped)

        await eventually { await fixture.coordinator.hasActiveDownloads == false }
        #expect(fixture.recorder.engines.count == 1)
        #expect(fixture.recorder.muxCallCount == 0)
        #expect(try await fixture.library.videoPairs().count == 1)
    }

    @Test func aStreamFailingEndsThePairWithoutMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.add()
        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2, as: .error)

        await eventually { await fixture.coordinator.hasActiveDownloads == false }
        #expect(fixture.recorder.muxCallCount == 0)
    }

    @Test func resumingSkipsAFinishedStream() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2, as: .stopped)
        await eventually { await fixture.coordinator.hasActiveDownloads == false }

        // Either stream's row can resume the pair.
        try await fixture.coordinator.resume(pair.videoGID)
        try await fixture.finish(engine: 3)

        #expect(fixture.recorder.engines[2].request.customFileName == "t_audio.m4a")
        await eventually { fixture.recorder.pairResults.count == 1 }
    }

    @Test func aRunningPairCantBeStartedAgain() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        await eventually { fixture.recorder.engines.count == 1 }

        await #expect(throws: DownloadControlError.pairInProgress) {
            try await fixture.coordinator.resume(pair.audioGID)
        }
        fixture.recorder.engines[0].end(status: .stopped)
    }

    @Test func addingWithoutStartingStartsNothing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add(startNow: false)

        #expect(try await fixture.library.download(pair.videoGID)?.status == .stopped)
        #expect(fixture.recorder.engines.isEmpty)
    }

    @Test func aPairIsActiveWhileMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.holdMuxes()
        let pair = try await fixture.add()
        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2)
        await eventually { fixture.recorder.muxCallCount == 1 }

        #expect(await fixture.coordinator.hasActiveDownloads)
        #expect(fixture.recorder.activePairs == [pair.videoGID])
        #expect(try await fixture.library.videoPair(containing: pair.videoGID)?.muxingStatus == .muxing)

        fixture.recorder.releaseMuxes()
        await eventually { await fixture.coordinator.hasActiveDownloads == false }
        await eventually { fixture.recorder.activePairs.isEmpty }
    }

    @Test func streamsAreMarkedSoOnlyThePairIsAnnounced() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.add()
        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2)

        await eventually { fixture.recorder.pairResults.count == 1 }
        await eventually { fixture.recorder.finishedDownloads.count == 2 }
        #expect(fixture.recorder.finishedDownloads.filter(\.isVideoPairStream).count == 2)
    }
}

@Suite("Video pairs: muxing failures")
struct VideoPairMuxFailureTests {
    private func failedPair(
        _ fixture: PairFixture,
        _ failure: VideoMuxer.Failure
    ) async throws -> VideoPair {
        fixture.recorder.setMuxResult(.failure(failure))
        let pair = try await fixture.add()
        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2)
        await eventually { fixture.recorder.pairResults.count == 1 }
        return pair
    }

    @Test func aFailureKeepsBothStreams() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await failedPair(fixture, .failed(message: "bad"))

        #expect(fixture.recorder.pairResults[0].outcome == .muxingFailed(message: "bad"))
        #expect(try await fixture.library.videoPair(containing: pair.videoGID)?.muxingStatus == .error)
        #expect(try await fixture.library.download(pair.audioGID) != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.path("t_video.mp4")))
    }

    @Test func tooLittleSpaceIsReported() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        _ = try await failedPair(fixture, .notEnoughSpace(folder: "/full"))
        #expect(fixture.recorder.pairResults[0].outcome == .notEnoughSpace(folder: "/full"))
    }

    @Test func muxingCanBeTriedAgain() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await failedPair(fixture, .failed(message: "bad"))
        await eventually { await fixture.coordinator.hasActiveDownloads == false }

        fixture.recorder.setMuxResult(.success(VideoMuxer.Output(fileName: "t.mp4", path: "/final/t.mp4", bytes: 7)))
        try await fixture.coordinator.muxAgain(pair.audioGID)

        await eventually { fixture.recorder.pairResults.count == 2 }
        #expect(fixture.recorder.pairResults[1].outcome == .complete(fileName: "t.mp4", filePath: "/final/t.mp4"))
        #expect(try await fixture.library.videoPairs().isEmpty)
        // No stream was fetched a second time.
        #expect(fixture.recorder.engines.count == 2)
    }

    @Test func resumingAfterAFailureMuxesAgain() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await failedPair(fixture, .failed(message: "bad"))
        await eventually { await fixture.coordinator.hasActiveDownloads == false }

        try await fixture.coordinator.resume(pair.videoGID)

        await eventually { fixture.recorder.muxCallCount == 2 }
        #expect(fixture.recorder.engines.count == 2)
    }
}

@Suite("Video pairs: in a Queue")
struct VideoPairQueueTests {
    @Test func theQueueRunsBothAndWaitsForMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.holdMuxes()
        let pair = try await fixture.add(to: fixture.queue, startNow: false)

        try await fixture.coordinator.startQueue(fixture.queue)

        // As with any Queue, the newest runs first, and that's the audio.
        try await fixture.finish(engine: 1)
        #expect(fixture.recorder.engines[0].request.customFileName == "t_audio.m4a")
        await fixture.clock.waitForSleepers(count: 1)
        fixture.clock.advance(by: .seconds(3))

        try await fixture.finish(engine: 2)
        #expect(fixture.recorder.engines[1].request.customFileName == "t_video.mp4")
        await eventually { fixture.recorder.muxCallCount == 1 }

        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.recorder.outcomes.isEmpty)
        #expect(fixture.clock.sleeperCount == 0)

        fixture.recorder.releaseMuxes()
        await fixture.clock.waitForSleepers(count: 1)
        fixture.clock.advance(by: .seconds(3))
        await eventually { fixture.recorder.outcomes == [.completed] }
        #expect(try await fixture.library.download(pair.audioGID) == nil)
    }

    @Test func aQueuesStreamsCantBeRunByHand() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add(to: fixture.queue, startNow: false)

        await #expect(throws: DownloadControlError.managedByQueue(fixture.queue)) {
            try await fixture.coordinator.resume(pair.videoGID)
        }
    }

    @Test func aPairOutsideAQueueCantBeMuxedDuringItsRun() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add(to: fixture.queue, startNow: false)
        try await fixture.coordinator.startQueue(fixture.queue)

        await #expect(throws: DownloadControlError.queueRunning(fixture.queue)) {
            try await fixture.coordinator.muxAgain(pair.videoGID)
        }

        await fixture.coordinator.stopQueue(fixture.queue)
        await eventually { fixture.recorder.engines.count == 1 }
        fixture.recorder.engines[0].end(status: .stopped)
    }
}

@Suite("Video pairs: shutdown")
struct VideoPairShutdownTests {
    @Test func aShutdownWaitsForMuxing() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        fixture.recorder.holdMuxes()
        let pair = try await fixture.add()
        await fixture.coordinator.setShutdownAfterDownload(true, for: pair.videoGID)

        try await fixture.finish(engine: 1)
        try await fixture.finish(engine: 2)
        await eventually { fixture.recorder.muxCallCount == 1 }

        // The sequence hasn't begun: nothing is waiting for the shutdown delay.
        #expect(fixture.clock.sleeperCount == 0)
        fixture.recorder.releaseMuxes()

        await fixture.clock.waitForSleepers(count: 1)
        fixture.clock.advance(by: .seconds(20))
        await eventually { fixture.recorder.shutdownCount == 1 }
    }

    @Test func stoppingAPairCancelsItsShutdown() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        await fixture.coordinator.setShutdownAfterDownload(true, for: pair.videoGID)
        await eventually { fixture.recorder.engines.count == 1 }

        try await fixture.coordinator.stop(pair.videoGID)
        fixture.recorder.engines[0].end(status: .stopped)
        await eventually { await fixture.coordinator.hasActiveDownloads == false }

        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.clock.sleeperCount == 0)
        #expect(fixture.recorder.shutdownCount == 0)
    }
}

@Suite("Video pairs: removing and moving")
struct VideoPairListTests {
    @Test func removingOneStreamRemovesBoth() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add(startNow: false)

        let refusals = try await fixture.coordinator.remove([pair.audioGID], deletingFiles: false)

        #expect(refusals.isEmpty)
        #expect(try await fixture.library.download(pair.videoGID) == nil)
        #expect(try await fixture.library.download(pair.audioGID) == nil)
        #expect(try await fixture.library.videoPairs().isEmpty)
    }

    @Test func aRunningPairCantBeRemoved() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        await eventually { fixture.recorder.engines.count == 1 }

        let refusals = try await fixture.coordinator.remove([pair.audioGID], deletingFiles: true)

        #expect(refusals == [.pairInProgress])
        #expect(try await fixture.library.download(pair.videoGID) != nil)
        fixture.recorder.engines[0].end(status: .stopped)
    }

    /// D33: Persepolis deletes `name*`, which takes other files that start the same way.
    @Test func removingDeletesOnlyYtDlpsOwnPartialFiles() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let gid = try await fixture.coordinator.add(
            fixture.stream("clip.mp4"),
            secrets: DownloadSecrets(),
            to: fixture.single,
            startNow: false
        )
        let ownFiles = ["clip.mp4.part", "clip.mp4.ytdl", "clip.mp4.part-Frag12", "clip.mp4.part-Frag12.part"]
        let otherFiles = ["clip.mp4", "clip.mp4.backup", "clip.mp4_old.mp4"]
        for name in ownFiles + otherFiles {
            try "x".write(toFile: fixture.path(name), atomically: true, encoding: .utf8)
        }

        _ = try await fixture.coordinator.remove([gid], deletingFiles: false)

        for name in ownFiles {
            #expect(!FileManager.default.fileExists(atPath: fixture.path(name)), "\(name)")
        }
        for name in otherFiles {
            #expect(FileManager.default.fileExists(atPath: fixture.path(name)), "\(name)")
        }
    }

    @Test func aFinishedStreamStaysUnlessDeletionWasAskedFor() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add()
        try await fixture.finish(engine: 1)
        await eventually { fixture.recorder.engines.count == 2 }
        fixture.recorder.engines[1].end(status: .stopped)
        await eventually { await fixture.coordinator.hasActiveDownloads == false }

        _ = try await fixture.coordinator.remove([pair.videoGID], deletingFiles: false)

        #expect(FileManager.default.fileExists(atPath: fixture.path("t_video.mp4")))
    }

    @Test func movingOneStreamMovesBoth() async throws {
        let fixture = try await PairFixture()
        defer { fixture.cleanUp() }
        let pair = try await fixture.add(startNow: false)

        let refusals = try await fixture.coordinator.moveToCategory([pair.audioGID], category: fixture.queue)

        #expect(refusals.isEmpty)
        #expect(try await fixture.library.download(pair.videoGID)?.category == fixture.queue)
        #expect(try await fixture.library.download(pair.audioGID)?.category == fixture.queue)
    }

    @Test func aPlaylistIsNotLookedUp() async throws {
        let lookedUp = LookupLog()
        let library = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await library.prepareForLaunch()
        let coordinator = DownloadCoordinator(
            library: library,
            secrets: InMemorySecretStore(),
            makeEngine: { FakeEngine(request: $0, secrets: $1) },
            spider: { request, _ in
                lookedUp.add(request.link)
                return Spider.Findings()
            }
        )
        var playlist = DownloadRequest(link: "https://s/index.m3u8?t=1", folder: "/d", connections: 1)
        playlist.engine = .ytDlp
        var stream = DownloadRequest(link: "https://s/v.mp4", folder: "/d", connections: 1)
        stream.engine = .ytDlp

        _ = try await coordinator.add(playlist, secrets: DownloadSecrets(), to: CategoryKind.singleDownloadsName, startNow: false)
        _ = try await coordinator.add(stream, secrets: DownloadSecrets(), to: CategoryKind.singleDownloadsName, startNow: false)

        await eventually { lookedUp.links.contains("https://s/v.mp4") }
        #expect(!lookedUp.links.contains("https://s/index.m3u8?t=1"))
    }
}

private final class LookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var links: [String] { lock.withLock { list } }
    func add(_ link: String) { lock.withLock { list.append(link) } }
}
