import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisPersistence
import SwiftpolisServices
import SwiftpolisTestSupport

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Monday 3 November 2026, 10:00:00 UTC.
private let startOfTest = try! Date("2026-11-03T10:00:00Z", strategy: .iso8601)

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var engineList: [FakeEngine] = []
    private var outcomesList: [QueueOutcome] = []
    private var running: Set<String> = []
    private var shutdownEvents = 0
    private var shutdowns = 0
    var wait = QueueWait(hours: 0, minutes: 0)

    var engines: [FakeEngine] { lock.withLock { engineList } }
    var outcomes: [QueueOutcome] { lock.withLock { outcomesList } }
    var runningQueues: Set<String> { lock.withLock { running } }
    var shutdownEventCount: Int { lock.withLock { shutdownEvents } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var startedLinks: [String] { engines.map { String($0.request.link.dropFirst("https://x/".count)) } }

    func make(_ request: DownloadRequest, _ secrets: DownloadSecrets) -> any DownloadEngine {
        let engine = FakeEngine(request: request, secrets: secrets)
        lock.withLock { engineList.append(engine) }
        return engine
    }

    func recordShutdown() {
        lock.withLock { shutdowns += 1 }
    }

    func listen(to events: AsyncStream<DownloadEvent>) {
        Task {
            for await event in events {
                lock.withLock {
                    switch event {
                    case .queueFinished(_, let outcome): outcomesList.append(outcome)
                    case .queuesChanged(let names): running = names
                    case .shuttingDown: shutdownEvents += 1
                    default: break
                    }
                }
            }
        }
    }
}

private func eventually(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private struct Fixture {
    let library: LibraryRepository
    let clock = ManualClock(now: startOfTest)
    let recorder = Recorder()
    let coordinator: DownloadCoordinator
    let queue = "Scheduled Downloads"

    init(handsQueuesToSystem: Bool = false) async throws {
        library = LibraryRepository(modelContainer: try LibraryStore.makeInMemoryContainer())
        try await library.prepareForLaunch()
        let recorder = self.recorder
        coordinator = DownloadCoordinator(
            library: library,
            secrets: InMemorySecretStore(),
            clock: clock,
            calendar: utc,
            tick: .milliseconds(2),
            queueWait: { recorder.wait },
            shutDown: { recorder.recordShutdown() },
            makeEngine: { recorder.make($1, $2) },
            spider: { _, _ in Spider.Findings() },
            handsQueuesToSystem: handsQueuesToSystem
        )
        recorder.listen(to: coordinator.events)
    }

    /// Adds Downloads oldest first, as if the user added them in this order.
    @discardableResult
    func add(_ names: String...) async throws -> [GID] {
        var gids: [GID] = []
        for name in names {
            let request = DownloadRequest(link: "https://x/\(name)", folder: "/d", connections: 1)
            gids.append(try await coordinator.add(request, secrets: DownloadSecrets(), to: queue, startNow: false))
        }
        return gids
    }

    func options(_ change: (inout QueueOptions) -> Void) async throws {
        var options = QueueOptions()
        change(&options)
        try await coordinator.updateQueueOptions(options, named: queue)
    }

    func start() async throws {
        try await coordinator.startQueue(queue)
    }

    /// Waits for the given number of engines to be running, then ends the newest. If it's still
    /// within the time a Queue spends on each Download, the clock moves past that too.
    func finishEngine(number: Int, status: DownloadStatus = .complete, isWithinMinimumTime: Bool = true) async {
        await eventually { recorder.engines.count >= number && recorder.engines[number - 1].recordedCalls.contains("run") }
        recorder.engines[number - 1].end(status: status)
        guard isWithinMinimumTime else { return }
        await eventually { clock.sleeperCount >= 1 }
        clock.advance(by: .seconds(3))
    }

    func waitForFinish() async {
        await eventually { !recorder.outcomes.isEmpty }
    }
}

@Suite("Queue: order")
struct QueueOrderTests {
    // Recorded from real Persepolis: three files added a, b, c ran c, b, a.
    @Test("Downloads run newest first, one at a time")
    func newestFirst() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b", "c")
        try await fixture.start()

        await eventually { fixture.recorder.engines.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.recorder.startedLinks == ["c"])

        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2)
        await fixture.finishEngine(number: 3)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["c", "b", "a"])
        #expect(fixture.recorder.outcomes == [.completed])
    }

    @Test("Reverse runs them oldest first")
    func reversed() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b", "c")
        try await fixture.options { $0.isReversed = true }
        try await fixture.start()

        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2)
        await fixture.finishEngine(number: 3)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["a", "b", "c"])
    }

    @Test("the list's saved order is what runs")
    func movedOrder() async throws {
        let fixture = try await Fixture()
        let gids = try await fixture.add("a", "b", "c")
        try await fixture.coordinator.moveInQueue([gids[0]], queue: fixture.queue, direction: .up)
        try await fixture.start()

        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2)
        await fixture.finishEngine(number: 3)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["c", "a", "b"])
    }

    @Test("a Queue spends at least 3 seconds on each Download")
    func minimumTime() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.start()

        await eventually { fixture.recorder.engines.count == 1 && fixture.recorder.engines[0].recordedCalls.contains("run") }
        fixture.recorder.engines[0].end(status: .complete)
        await eventually { fixture.clock.sleeperCount == 1 }
        fixture.clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.recorder.engines.count == 1)

        fixture.clock.advance(by: .seconds(1))
        await eventually { fixture.recorder.engines.count == 2 }
    }

    @Test("complete Downloads are skipped")
    func skipsComplete() async throws {
        let fixture = try await Fixture()
        let gids = try await fixture.add("a", "b")
        try await fixture.library.saveProgress(
            DownloadProgress(status: .complete, fileName: "b", totalBytes: 1, downloadedBytes: 1),
            for: gids[1]
        )
        try await fixture.start()

        await fixture.finishEngine(number: 1)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["a"])
    }

    @Test("an empty Queue completes straight away")
    func empty() async throws {
        let fixture = try await Fixture()
        try await fixture.start()
        await fixture.waitForFinish()
        #expect(fixture.recorder.outcomes == [.completed])
        await eventually { fixture.recorder.runningQueues.isEmpty }
    }
}

@Suite("Queue: Passes")
struct QueuePassTests {
    @Test("a failing Download is tried on each of five Passes, then the Queue still completes")
    func fivePasses() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "bad", "c")
        try await fixture.start()

        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2, status: .error)
        await fixture.finishEngine(number: 3)
        for number in 4...7 {
            await fixture.finishEngine(number: number, status: .error)
        }
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["c", "bad", "a", "bad", "bad", "bad", "bad"])
        #expect(fixture.recorder.outcomes == [.completed])
    }

    @Test("a Download added while running waits for the next Pass")
    func addedWhileRunning() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.start()
        await eventually { fixture.recorder.engines.count == 1 }

        try await fixture.add("late")
        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["a", "late"])
    }
}

@Suite("Queue: stopping")
struct QueueStopTests {
    @Test("stopping stops the current Download, and nothing else starts")
    func stop() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        await fixture.coordinator.stopQueue(fixture.queue)
        await eventually { fixture.recorder.engines[0].recordedCalls.contains("stop") }
        fixture.recorder.engines[0].end(status: .stopped)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["b"])
        #expect(fixture.recorder.outcomes == [.stoppedByUser])
        await eventually { fixture.recorder.runningQueues.isEmpty }
    }

    @Test("a running Queue is reported, and refuses to be started twice")
    func running() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.start()
        try await fixture.start()

        await eventually { fixture.recorder.runningQueues == [fixture.queue] }
        await eventually { fixture.recorder.engines.count == 1 }
        #expect(await fixture.coordinator.runningQueues == [fixture.queue])
        #expect(await fixture.coordinator.hasActiveDownloads)

        await fixture.finishEngine(number: 1)
        await fixture.waitForFinish()
        #expect(fixture.recorder.engines.count == 1)
    }

    @Test("stop all stops a Queue too")
    func stopAll() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        await fixture.coordinator.stopAll()
        await eventually { fixture.recorder.engines[0].recordedCalls.contains("stop") }
        fixture.recorder.engines[0].end(status: .stopped)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()

        #expect(fixture.recorder.outcomes == [.stoppedByUser])
    }

    @Test("while it runs, its Downloads can't be removed, moved or reordered")
    func refusals() async throws {
        let fixture = try await Fixture()
        let gids = try await fixture.add("a", "b")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        let removal = try await fixture.coordinator.remove([gids[0]], deletingFiles: false)
        #expect(removal == [.queueRunning(fixture.queue)])

        let moving = try await fixture.coordinator.moveToCategory([gids[0]], category: "Single Downloads")
        #expect(moving == [.queueRunning(fixture.queue)])

        await #expect(throws: DownloadControlError.queueRunning(fixture.queue)) {
            try await fixture.coordinator.moveInQueue([gids[0]], queue: fixture.queue, direction: .up)
        }
        await #expect(throws: DownloadControlError.downloadsActive) {
            try await fixture.coordinator.clearList()
        }
    }

    @Test("a running Queue can't be removed, and a stopped one takes its Downloads with it")
    func removeQueue() async throws {
        let fixture = try await Fixture()
        try await fixture.coordinator.createQueue(named: "Movies")
        let request = DownloadRequest(link: "https://x/a", folder: "/d", connections: 1)
        _ = try await fixture.coordinator.add(request, secrets: DownloadSecrets(), to: "Movies", startNow: false)
        try await fixture.coordinator.startQueue("Movies")
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        await #expect(throws: DownloadControlError.queueRunning("Movies")) {
            try await fixture.coordinator.removeQueue(named: "Movies")
        }

        await fixture.finishEngine(number: 1)
        await fixture.waitForFinish()
        try await fixture.coordinator.removeQueue(named: "Movies")

        #expect(try await fixture.library.categories().map(\.name) == CategoryKind.builtInNames)
        #expect(try await fixture.library.downloads(in: "All Downloads").isEmpty)
    }
}

@Suite("Queue: schedule")
struct QueueScheduleTests {
    @Test("the Start time holds the first unfinished Download, and only that one")
    func startTime() async throws {
        let fixture = try await Fixture()
        let gids = try await fixture.add("a", "b", "done")
        try await fixture.library.saveProgress(
            DownloadProgress(status: .complete, fileName: "done", totalBytes: 1, downloadedBytes: 1),
            for: gids[2]
        )
        try await fixture.options {
            $0.startTimeEnabled = true
            $0.startTime = ClockTime(hour: 10, minute: 5)!
        }
        try await fixture.start()

        await eventually { fixture.clock.sleeperCount == 1 }
        #expect(fixture.recorder.engines.first?.recordedCalls.contains("run") != true)

        fixture.clock.advance(by: .seconds(299))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.recorder.engines.first?.recordedCalls.contains("run") != true)

        fixture.clock.advance(by: .seconds(1))
        await fixture.finishEngine(number: 1, isWithinMinimumTime: false)

        // The next one starts straight away, with no Start time of its own.
        await fixture.finishEngine(number: 2)
        await fixture.waitForFinish()
        #expect(fixture.recorder.startedLinks == ["b", "a"])
    }

    @Test("stopping a Queue that's waiting for its Start time ends it without running anything")
    func stopWhileWaiting() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.options {
            $0.startTimeEnabled = true
            $0.startTime = ClockTime(hour: 10, minute: 5)!
        }
        try await fixture.start()
        await eventually { fixture.clock.sleeperCount == 1 }

        await fixture.coordinator.stopQueue(fixture.queue)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()

        #expect(fixture.recorder.engines.first?.recordedCalls.contains("run") != true)
        #expect(fixture.recorder.outcomes == [.stoppedByUser])
    }

    @Test("the End time stops the Queue, leaving the rest unstarted")
    func endTime() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.options {
            $0.endTimeEnabled = true
            $0.endTime = ClockTime(hour: 10, minute: 5)!
        }
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        await eventually { fixture.clock.sleeperCount == 1 }

        fixture.clock.advance(by: .seconds(300))
        await eventually { fixture.recorder.engines[0].recordedCalls.contains("stop") }
        fixture.recorder.engines[0].end(status: .stopped)
        await fixture.waitForFinish()

        #expect(fixture.recorder.startedLinks == ["b"])
        #expect(fixture.recorder.outcomes == [.stoppedBySchedule(message: nil)])
    }

    @Test("a Download finishing before the End time stays complete, and the next one runs (fixes D2)")
    func finishBeforeEnd() async throws {
        let fixture = try await Fixture()
        let gids = try await fixture.add("a", "b")
        try await fixture.options {
            $0.endTimeEnabled = true
            $0.endTime = ClockTime(hour: 10, minute: 5)!
        }
        try await fixture.start()

        await fixture.finishEngine(number: 1)
        await fixture.finishEngine(number: 2)
        await fixture.waitForFinish()
        fixture.clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(30))

        #expect(try await fixture.library.download(gids[1])?.status == .complete)
        #expect(fixture.recorder.engines.allSatisfy { !$0.recordedCalls.contains("stop") })
    }

    // The scenario from Q17, on a Queue.
    @Test("waking after the whole window stops the Queue and says why")
    func missedWindow() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.options {
            $0.startTimeEnabled = true
            $0.startTime = ClockTime(hour: 10, minute: 5)!
            $0.endTimeEnabled = true
            $0.endTime = ClockTime(hour: 10, minute: 10)!
        }
        try await fixture.start()
        await eventually { fixture.clock.sleeperCount == 1 }

        fixture.clock.advance(by: .seconds(3_600))
        await fixture.waitForFinish()

        #expect(fixture.recorder.engines.first?.recordedCalls.contains("run") != true)
        guard case .stoppedBySchedule(let message) = fixture.recorder.outcomes.first else {
            Issue.record("Expected the schedule to have stopped it")
            return
        }
        #expect(message?.contains("scheduled") == true)
    }

    @Test("the Queue wait applies to every Download but the first")
    func queueWait() async throws {
        let fixture = try await Fixture()
        fixture.recorder.wait = QueueWait(hours: 0, minutes: 1)
        try await fixture.add("a", "b")
        try await fixture.start()

        await fixture.finishEngine(number: 1)

        // The clock is now 10:00:03, so the wait lands on 10:01:00.
        await eventually { fixture.recorder.engines.count == 2 }
        await eventually { fixture.clock.sleeperCount == 1 }
        #expect(!fixture.recorder.engines[1].recordedCalls.contains("run"))

        fixture.clock.advance(by: .seconds(56))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!fixture.recorder.engines[1].recordedCalls.contains("run"))

        fixture.clock.advance(by: .seconds(1))
        await fixture.finishEngine(number: 2, isWithinMinimumTime: false)
        await fixture.waitForFinish()
    }
}

@Suite("Queue: Speed dial")
struct QueueSpeedDialTests {
    @Test("each Queue has its own dial, which applies now and to later Downloads (fixes D9)")
    func dial() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a", "b")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }

        await fixture.coordinator.setSpeedDial(3, queue: fixture.queue)
        #expect(fixture.recorder.engines[0].recordedCalls.contains("dial 3"))

        await fixture.finishEngine(number: 1)
        await eventually { fixture.recorder.engines.count == 2 }
        #expect(fixture.recorder.engines[1].recordedCalls.contains("dial 3"))

        await fixture.finishEngine(number: 2)
        await fixture.waitForFinish()
    }
}

@Suite("Queue and Single Download: shutdown")
struct ShutdownTests {
    @Test("a completed Queue shuts the Mac down, after the delay")
    func queueCompletes() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        await fixture.coordinator.setShutdownAfterQueue(true, queue: fixture.queue)

        await fixture.finishEngine(number: 1)
        await fixture.waitForFinish()
        await eventually { fixture.recorder.shutdownEventCount == 1 }
        await eventually { fixture.clock.sleeperCount == 1 }
        #expect(fixture.recorder.shutdownCount == 0)

        fixture.clock.advance(by: .seconds(19))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.recorder.shutdownCount == 0)

        fixture.clock.advance(by: .seconds(1))
        await eventually { fixture.recorder.shutdownCount == 1 }
    }

    @Test("stopping the Queue cancels it")
    func queueStopped() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        await fixture.coordinator.setShutdownAfterQueue(true, queue: fixture.queue)

        await fixture.coordinator.stopQueue(fixture.queue)
        fixture.recorder.engines[0].end(status: .stopped)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.recorder.shutdownEventCount == 0)
    }

    // queue.py leaves `start` set when the End time stops a Queue, so its shutdown still happens.
    @Test("a Queue stopped by its End time still shuts down, as someone leaving it overnight would want")
    func endTimeStillShutsDown() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.options {
            $0.endTimeEnabled = true
            $0.endTime = ClockTime(hour: 10, minute: 5)!
        }
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        await eventually { fixture.clock.sleeperCount == 1 }
        await fixture.coordinator.setShutdownAfterQueue(true, queue: fixture.queue)

        fixture.clock.advance(by: .seconds(300))
        await eventually { fixture.recorder.engines[0].recordedCalls.contains("stop") }
        fixture.recorder.engines[0].end(status: .stopped)
        await fixture.waitForFinish()

        await eventually { fixture.recorder.shutdownEventCount == 1 }
    }

    @Test("turning it off cancels it")
    func turnedOff() async throws {
        let fixture = try await Fixture()
        try await fixture.add("a")
        try await fixture.start()
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        await fixture.coordinator.setShutdownAfterQueue(true, queue: fixture.queue)
        await fixture.coordinator.setShutdownAfterQueue(false, queue: fixture.queue)

        await fixture.finishEngine(number: 1)
        await fixture.waitForFinish()
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.recorder.shutdownEventCount == 0)
    }

    private func runSingle(_ fixture: Fixture) async throws -> GID {
        let request = DownloadRequest(link: "https://x/a", folder: "/d", connections: 1)
        let gid = try await fixture.coordinator.add(request, secrets: DownloadSecrets(), to: "Single Downloads", startNow: true)
        await eventually { fixture.recorder.engines.first?.recordedCalls.contains("run") == true }
        return gid
    }

    @Test("a Single Download finishing, even with an error, shuts down", arguments: [DownloadStatus.complete, .error])
    func singleFinishes(status: DownloadStatus) async throws {
        let fixture = try await Fixture()
        let gid = try await runSingle(fixture)
        await fixture.coordinator.setShutdownAfterDownload(true, for: gid)

        fixture.recorder.engines[0].end(status: status)

        await eventually { fixture.recorder.shutdownEventCount == 1 }
        await eventually { fixture.clock.sleeperCount == 1 }
        fixture.clock.advance(by: .seconds(20))
        await eventually { fixture.recorder.shutdownCount == 1 }
    }

    @Test("stopping a Single Download by hand cancels it")
    func singleStopped() async throws {
        let fixture = try await Fixture()
        let gid = try await runSingle(fixture)
        await fixture.coordinator.setShutdownAfterDownload(true, for: gid)

        try await fixture.coordinator.stop(gid)
        fixture.recorder.engines[0].end(status: .stopped)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.recorder.shutdownEventCount == 0)
    }

    @Test("stop all cancels it too")
    func stopAllCancels() async throws {
        let fixture = try await Fixture()
        let gid = try await runSingle(fixture)
        await fixture.coordinator.setShutdownAfterDownload(true, for: gid)

        await fixture.coordinator.stopAll()
        fixture.recorder.engines[0].end(status: .stopped)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.recorder.shutdownEventCount == 0)
    }

    @Test("everything else is stopped first, and it waits for sessions to close")
    func stopsEverything() async throws {
        let fixture = try await Fixture()
        let gid = try await runSingle(fixture)
        let otherRequest = DownloadRequest(link: "https://x/b", folder: "/d", connections: 1)
        _ = try await fixture.coordinator.add(otherRequest, secrets: DownloadSecrets(), to: "Single Downloads", startNow: true)
        await eventually { fixture.recorder.engines.count == 2 }
        await fixture.coordinator.setShutdownAfterDownload(true, for: gid)

        fixture.recorder.engines[0].end(status: .complete)
        await eventually { fixture.recorder.engines[1].recordedCalls.contains("stop") }
        await eventually { fixture.clock.sleeperCount == 1 }
        fixture.clock.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.recorder.shutdownCount == 0)

        fixture.recorder.engines[1].end(status: .stopped)
        await eventually { fixture.recorder.shutdownCount == 1 }
    }
}

@Suite("Queue: handed to the system, as on iOS")
struct QueueHandedOverTests {
    @Test("every Download starts straight away, in the Queue's order")
    func allAtOnce() async throws {
        let fixture = try await Fixture(handsQueuesToSystem: true)
        try await fixture.add("a", "b", "c")
        try await fixture.start()

        await eventually { fixture.recorder.engines.count == 3 }
        #expect(fixture.recorder.startedLinks == ["c", "b", "a"])

        for engine in fixture.recorder.engines { engine.end(status: .complete) }
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()
        #expect(fixture.recorder.outcomes == [.completed])
    }

    @Test("only what failed goes round again")
    func failuresGetAnotherPass() async throws {
        let fixture = try await Fixture(handsQueuesToSystem: true)
        try await fixture.add("a", "b")
        try await fixture.start()

        await eventually { fixture.recorder.engines.count == 2 }
        fixture.recorder.engines[0].end(status: .complete)
        fixture.recorder.engines[1].end(status: .error)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))

        await eventually { fixture.recorder.engines.count == 3 }
        #expect(fixture.recorder.startedLinks == ["b", "a", "a"])
        fixture.recorder.engines[2].end(status: .complete)
        await eventually { fixture.clock.sleeperCount >= 1 }
        fixture.clock.advance(by: .seconds(3))
        await fixture.waitForFinish()
    }

    @Test("stopping the Queue stops all of them, and nothing goes round again")
    func stopping() async throws {
        let fixture = try await Fixture(handsQueuesToSystem: true)
        try await fixture.add("a", "b")
        try await fixture.start()

        await eventually { fixture.recorder.engines.count == 2 }
        try await Task.sleep(for: .milliseconds(120))
        await fixture.coordinator.stopQueue(fixture.queue)
        await eventually {
            fixture.recorder.engines.allSatisfy { $0.recordedCalls.contains("stop") }
        }
        for engine in fixture.recorder.engines { engine.end() }

        await fixture.waitForFinish()
        #expect(fixture.recorder.outcomes == [.stoppedByUser])
        #expect(fixture.recorder.engines.count == 2)
    }

    @Test("after a relaunch, a Queue with a Download the system kept starts again")
    func adoptingAQueuedDownload() async throws {
        let fixture = try await Fixture(handsQueuesToSystem: true)
        let gids = try await fixture.add("a", "b")

        await fixture.coordinator.adopt([gids[0]])

        await eventually { fixture.recorder.engines.count == 2 }
        #expect(fixture.recorder.runningQueues == [fixture.queue])
    }

    @Test("after a relaunch, a Single Download the system kept carries on alone")
    func adoptingASingleDownload() async throws {
        let fixture = try await Fixture(handsQueuesToSystem: true)
        let request = DownloadRequest(link: "https://x/kept", folder: "/d", connections: 1)
        let gid = try await fixture.coordinator.add(
            request, secrets: DownloadSecrets(), to: CategoryKind.singleDownloadsName, startNow: false
        )

        await fixture.coordinator.adopt([gid])

        await eventually { fixture.recorder.engines.count == 1 }
        #expect(fixture.recorder.startedLinks == ["kept"])
    }
}
