import Foundation
import Testing
import SwiftpolisDomain

@Suite("ClockTime")
struct ClockTimeTests {
    @Test("parses the forms Persepolis stores", arguments: [
        ("0:0", 0, 0),
        ("5:7", 5, 7),
        ("05:07", 5, 7),
        ("23:59", 23, 59),
    ])
    func parses(text: String, hour: Int, minute: Int) {
        #expect(ClockTime(text) == ClockTime(hour: hour, minute: minute))
    }

    @Test("rejects anything else", arguments: ["", "12", "24:00", "12:60", "-1:00", "a:b", "1:2:3"])
    func rejects(text: String) {
        #expect(ClockTime(text) == nil)
    }

    @Test("rejects out-of-range components")
    func rejectsComponents() {
        #expect(ClockTime(hour: 24, minute: 0) == nil)
        #expect(ClockTime(hour: 0, minute: 60) == nil)
    }

    @Test("converts to and from minutes since midnight")
    func minutesSinceMidnight() {
        #expect(ClockTime(hour: 2, minute: 30)?.minutesSinceMidnight == 150)
        #expect(ClockTime(minutesSinceMidnight: 150) == ClockTime(hour: 2, minute: 30))
        #expect(ClockTime(minutesSinceMidnight: 1_440) == nil)
    }

    @Test("a time later today is today")
    func laterToday() throws {
        let time = try #require(ClockTime(hour: 14, minute: 0))
        let next = time.nextOccurrence(from: utc("2026-11-03T10:00:00Z"), calendar: .utc)
        #expect(next == utc("2026-11-03T14:00:00Z"))
    }

    @Test("a time earlier today is tomorrow")
    func earlierToday() throws {
        let time = try #require(ClockTime(hour: 2, minute: 0))
        let next = time.nextOccurrence(from: utc("2026-11-03T10:00:00Z"), calendar: .utc)
        #expect(next == utc("2026-11-04T02:00:00Z"))
    }

    @Test("the current minute counts, as in Persepolis")
    func currentMinute() throws {
        let time = try #require(ClockTime(hour: 10, minute: 0))
        let next = time.nextOccurrence(from: utc("2026-11-03T10:00:45Z"), calendar: .utc)
        #expect(next == utc("2026-11-03T10:00:00Z"))
    }

    @Test("a time the clocks skip fires when they jump past it")
    func daylightSavingGap() throws {
        // New York jumped from 02:00 to 03:00 local (07:00 UTC) on 8 March 2026.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))

        let time = try #require(ClockTime(hour: 2, minute: 30))
        let next = time.nextOccurrence(from: utc("2026-03-08T06:00:00Z"), calendar: newYork)
        #expect(next == utc("2026-03-08T07:00:00Z"))
    }
}

private func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

extension Calendar {
    fileprivate static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
