import Foundation

/// The source of the current time, so schedule rules can be tested without waiting for it.
public protocol WallClock: Sendable {
    var now: Date { get }
    func sleep(until date: Date) async throws
}

public struct SystemClock: WallClock {
    public init() {}

    public var now: Date { Date() }

    /// Wakes every second to look at the clock, so that changing the time, or the Mac sleeping
    /// past `date`, is noticed.
    public func sleep(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(min(remaining, 1)), clock: .continuous)
        }
    }
}
