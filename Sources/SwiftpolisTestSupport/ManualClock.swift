import Foundation
import SwiftpolisDomain

/// A clock that only moves when a test tells it to.
public final class ManualClock: WallClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentTime: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeSleeping: Set<UUID> = []

    public init(now: Date) {
        currentTime = now
    }

    public var now: Date {
        lock.withLock { currentTime }
    }

    public func advance(by duration: Duration) {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        let woken = lock.withLock {
            currentTime.addTimeInterval(seconds)
            let due = sleepers.filter { $0.value.deadline <= currentTime }
            for id in due.keys { sleepers[id] = nil }
            return due.values
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }

    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Returns once `count` tasks are asleep, so a test can advance time without racing them.
    public func waitForSleepers(count: Int) async {
        while lock.withLock({ sleepers.count }) < count {
            await Task.yield()
        }
    }

    public func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome: Result<Void, Error>? = lock.withLock {
                    if cancelledBeforeSleeping.remove(id) != nil { return .failure(CancellationError()) }
                    if date <= currentTime { return .success(()) }
                    sleepers[id] = Sleeper(deadline: date, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = lock.withLock {
                let sleeper = sleepers.removeValue(forKey: id)
                if sleeper == nil { cancelledBeforeSleeping.insert(id) }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
