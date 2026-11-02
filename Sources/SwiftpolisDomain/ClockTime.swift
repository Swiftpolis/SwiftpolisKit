import Foundation

/// A time of day with no date, used for Start times and End times.
public struct ClockTime: Hashable, Sendable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init?(minutesSinceMidnight minutes: Int) {
        guard minutes >= 0 else { return nil }
        self.init(hour: minutes / 60, minute: minutes % 60)
    }

    /// Parses the `H:M` and `HH:MM` forms Persepolis stores.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        self.init(hour: hour, minute: minute)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// The next moment this time occurs, counting the minute `date` is in.
    ///
    /// If the clocks skip this time, as they do when daylight saving starts, the result is the
    /// moment they jump past it.
    public func nextOccurrence(from date: Date, calendar: Calendar) -> Date {
        let current = calendar.dateComponents([.hour, .minute], from: date)
        if current.hour == hour, current.minute == minute,
           let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start {
            return minuteStart
        }
        let target = DateComponents(hour: hour, minute: minute)
        guard let next = calendar.nextDate(after: date, matching: target, matchingPolicy: .nextTime)
        else {
            preconditionFailure("Every valid time of day recurs in the Gregorian calendar")
        }
        return next
    }
}
