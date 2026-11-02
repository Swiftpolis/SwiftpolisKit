import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisTestSupport

@Suite("ManualClock")
struct ManualClockTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("time only moves when told to")
    func moves() {
        let clock = ManualClock(now: start)
        #expect(clock.now == start)
        clock.advance(by: .seconds(60))
        #expect(clock.now == start.addingTimeInterval(60))
    }

    @Test("a sleeper wakes once its time arrives, and not before")
    func wakesSleeper() async throws {
        let clock = ManualClock(now: start)
        let woke = Flag()
        let sleeper = Task {
            try await clock.sleep(until: start.addingTimeInterval(60))
            woke.set()
        }
        await clock.waitForSleepers(count: 1)

        clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(!woke.isSet)

        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(woke.isSet)
    }

    @Test("sleeping until a past time returns straight away")
    func pastTime() async throws {
        let clock = ManualClock(now: start)
        try await clock.sleep(until: start.addingTimeInterval(-1))
    }

    @Test("cancelling a sleeper throws and doesn't wait for the time")
    func cancellation() async {
        let clock = ManualClock(now: start)
        let sleeper = Task { try await clock.sleep(until: start.addingTimeInterval(60)) }
        await clock.waitForSleepers(count: 1)

        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
