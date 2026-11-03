import Foundation

/// The real moments a Download may run between, worked out once from clock times.
///
/// Persepolis compares the clock with a time for an exact minute, so a Mac asleep through that
/// minute misses it and waits a day. Comparing with moments means a late wake can still act.
public struct ScheduleWindow: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case wait(until: Date)
        case start
        /// The whole window passed before the Download could start.
        case missed
    }

    public let start: Date?
    public let end: Date?

    public init(start: Date?, end: Date?) {
        self.start = start
        self.end = end
    }

    /// The End time is the first one after the Start time, so a window can cross midnight. With no
    /// Start time, it counts from now.
    public init(start: ClockTime?, end: ClockTime?, now: Date, calendar: Calendar) {
        let startDate = start?.nextOccurrence(from: now, calendar: calendar)
        self.start = startDate
        self.end = end?.nextOccurrence(
            from: startDate?.addingTimeInterval(60) ?? now,
            calendar: calendar
        )
    }

    public func decision(at now: Date) -> Decision {
        if let start, now < start { return .wait(until: start) }
        if let end, now >= end { return .missed }
        return .start
    }
}

/// The pause before each Download in a Queue except the first.
public struct QueueWait: Equatable, Sendable {
    public var hours: Int
    public var minutes: Int

    public init(hours: Int, minutes: Int) {
        self.hours = hours
        self.minutes = minutes
    }

    /// When the next Download should start, or `nil` for no wait. As in Persepolis, this lands on a
    /// clock minute, and past 30 seconds it adds a minute so the wait isn't much shorter than asked.
    public func startDate(after now: Date, calendar: Calendar) -> Date? {
        guard hours != 0 || minutes != 0 else { return nil }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: now)
        let roundUp = (parts.second ?? 0) > 30 ? 1 : 0
        let total = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) + roundUp + hours * 60 + minutes
        guard let time = ClockTime(minutesSinceMidnight: total % (24 * 60)),
              let thisMinute = calendar.dateInterval(of: .minute, for: now)?.start
        else { return nil }
        return time.nextOccurrence(from: thisMinute.addingTimeInterval(60), calendar: calendar)
    }
}
