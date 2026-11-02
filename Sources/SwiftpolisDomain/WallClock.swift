import Foundation

/// The source of the current time, so schedule rules can be tested without waiting for it.
public protocol WallClock: Sendable {
    var now: Date { get }
    func sleep(until date: Date) async throws
}

public struct SystemClock: WallClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until date: Date) async throws {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return }
        try await Task.sleep(for: .seconds(remaining), clock: .continuous)
    }
}
