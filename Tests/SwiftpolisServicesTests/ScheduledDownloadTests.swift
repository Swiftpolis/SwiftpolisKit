import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisServices
import SwiftpolisTestSupport

@Suite("Scheduled download")
struct ScheduledDownloadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let clock: ManualClock
        let engine: FakeEngine
        let scheduled: ScheduledDownload
        let run: Task<Void, Never>
    }

    private func start(startIn: TimeInterval? = nil, endIn: TimeInterval? = nil) -> Fixture {
        let clock = ManualClock(now: now)
        let engine = FakeEngine(
            request: DownloadRequest(link: "https://a", customFileName: "a.zip", folder: "/d", connections: 1),
            secrets: DownloadSecrets()
        )
        let scheduled = ScheduledDownload(
            engine: engine,
            window: ScheduleWindow(
                start: startIn.map { now.addingTimeInterval($0) },
                end: endIn.map { now.addingTimeInterval($0) }
            ),
            clock: clock
        )
        return Fixture(clock: clock, engine: engine, scheduled: scheduled, run: Task { await scheduled.run() })
    }

    private func waitForEngine(_ fixture: Fixture, toRecord call: String = "run") async {
        while !fixture.engine.recordedCalls.contains(call) { await Task.yield() }
    }

    @Test("it shows as scheduled until the Start time, and the engine doesn't run")
    func waits() async {
        let fixture = start(startIn: 60)
        await fixture.clock.waitForSleepers(count: 1)

        #expect(fixture.scheduled.snapshot.status == .scheduled)
        #expect(fixture.scheduled.snapshot.fileName == "a.zip")

        fixture.clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(fixture.engine.recordedCalls.isEmpty)

        fixture.clock.advance(by: .seconds(1))
        await waitForEngine(fixture)
        #expect(fixture.scheduled.snapshot.status == .downloading)

        fixture.engine.end(status: .complete)
        await fixture.run.value
        #expect(fixture.scheduled.snapshot.status == .complete)
    }

    @Test("stopping while scheduled ends it, and the engine never runs")
    func stopWhileScheduled() async {
        let fixture = start(startIn: 60)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.scheduled.stop()
        await fixture.run.value

        #expect(fixture.scheduled.snapshot.status == .stopped)
        #expect(fixture.engine.recordedCalls.isEmpty)
    }

    @Test("cancelling the task while scheduled does the same")
    func cancelWhileScheduled() async {
        let fixture = start(startIn: 60)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.run.cancel()
        await fixture.run.value

        #expect(fixture.scheduled.snapshot.status == .stopped)
    }

    @Test("pausing does nothing until it's running")
    func pauseWhileScheduled() async {
        let fixture = start(startIn: 60)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.scheduled.pause()

        #expect(fixture.scheduled.snapshot.status == .scheduled)
        #expect(!fixture.engine.recordedCalls.contains("pause"))
        fixture.scheduled.stop()
        await fixture.run.value
    }

    @Test("the End time stops a running download")
    func endTimeStops() async {
        let fixture = start(endIn: 60)
        await waitForEngine(fixture)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.clock.advance(by: .seconds(60))
        await waitForEngine(fixture, toRecord: "stop")
        fixture.engine.end(status: .stopped)
        await fixture.run.value

        #expect(fixture.scheduled.snapshot.status == .stopped)
    }

    @Test("a download that finishes before the End time stays complete (fixes D2)")
    func finishBeforeEnd() async {
        let fixture = start(endIn: 60)
        await waitForEngine(fixture)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.engine.end(status: .complete)
        await fixture.run.value
        fixture.clock.advance(by: .seconds(120))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(fixture.scheduled.snapshot.status == .complete)
        #expect(!fixture.engine.recordedCalls.contains("stop"))
    }

    @Test("waking inside the window starts late, and still stops on time (fixes D1)")
    func lateWake() async {
        let fixture = start(startIn: 60, endIn: 600)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.clock.advance(by: .seconds(300))
        await waitForEngine(fixture)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.clock.advance(by: .seconds(300))
        await waitForEngine(fixture, toRecord: "stop")
        fixture.engine.end(status: .stopped)
        await fixture.run.value
    }

    @Test("waking after the window doesn't start, and says why")
    func missedWindow() async {
        let fixture = start(startIn: 60, endIn: 600)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.clock.advance(by: .seconds(700))
        await fixture.run.value

        let snapshot = fixture.scheduled.snapshot
        #expect(snapshot.status == .stopped)
        #expect(snapshot.errorMessage?.contains("scheduled") == true)
        #expect(fixture.engine.recordedCalls.isEmpty)
    }

    @Test("once running, controls reach the engine")
    func passesThrough() async {
        let fixture = start()
        await waitForEngine(fixture)

        fixture.scheduled.pause()
        fixture.scheduled.unpause()
        fixture.scheduled.setSpeedDial(4)
        fixture.scheduled.stop()

        #expect(fixture.engine.recordedCalls.contains("pause"))
        #expect(fixture.engine.recordedCalls.contains("unpause"))
        #expect(fixture.engine.recordedCalls.contains("dial 4"))
        #expect(fixture.engine.recordedCalls.contains("stop"))
        fixture.engine.end()
        await fixture.run.value
    }

    @Test("a Speed dial set while scheduled applies once it runs")
    func dialWhileScheduled() async {
        let fixture = start(startIn: 60)
        await fixture.clock.waitForSleepers(count: 1)

        fixture.scheduled.setSpeedDial(2)
        fixture.clock.advance(by: .seconds(60))
        await waitForEngine(fixture)

        #expect(fixture.engine.recordedCalls.contains("dial 2"))
        fixture.engine.end()
        await fixture.run.value
    }
}
