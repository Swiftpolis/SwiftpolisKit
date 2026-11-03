import Foundation
import Testing
import SwiftpolisDomain

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ text: String) -> Date {
    try! Date("2026-11-03T\(text)Z", strategy: .iso8601)
}

private func tomorrow(_ text: String) -> Date {
    try! Date("2026-11-04T\(text)Z", strategy: .iso8601)
}

private func window(start: String? = nil, end: String? = nil, now: Date) -> ScheduleWindow {
    ScheduleWindow(
        start: start.flatMap(ClockTime.init),
        end: end.flatMap(ClockTime.init),
        now: now,
        calendar: utcCalendar
    )
}

@Suite("Schedule window")
struct ScheduleWindowTests {
    @Test("no times means start now, with no end")
    func noTimes() {
        let schedule = window(now: date("10:00:00"))
        #expect(schedule.decision(at: date("10:00:00")) == .start)
        #expect(schedule.end == nil)
    }

    @Test("it waits for the Start time")
    func waits() {
        let schedule = window(start: "14:00", now: date("10:00:00"))
        #expect(schedule.decision(at: date("10:00:00")) == .wait(until: date("14:00:00")))
        #expect(schedule.decision(at: date("13:59:59")) == .wait(until: date("14:00:00")))
        #expect(schedule.decision(at: date("14:00:00")) == .start)
    }

    @Test("a time already past today means tomorrow")
    func tomorrowsTime() {
        let schedule = window(start: "02:00", now: date("10:00:00"))
        #expect(schedule.start == tomorrow("02:00:00"))
    }

    @Test("the End time is the first one after the Start time, so a window can cross midnight")
    func crossingMidnight() {
        let schedule = window(start: "23:00", end: "01:00", now: date("10:00:00"))
        #expect(schedule.start == date("23:00:00"))
        #expect(schedule.end == tomorrow("01:00:00"))
    }

    @Test("a Start time and End time that match are a day apart, not zero seconds")
    func matchingTimes() {
        let schedule = window(start: "14:00", end: "14:00", now: date("10:00:00"))
        #expect(schedule.end == tomorrow("14:00:00"))
    }

    @Test("an End time alone counts from now")
    func endAlone() {
        let schedule = window(end: "14:00", now: date("10:00:00"))
        #expect(schedule.end == date("14:00:00"))
        #expect(schedule.decision(at: date("10:00:00")) == .start)
    }

    // The scenario from Q17: a Queue set for 02:00 to 06:00, with the Mac asleep past 02:00.
    @Test("waking inside the window starts straight away, and still ends on time (fixes D1)")
    func wakingInsideWindow() {
        let schedule = window(start: "02:00", end: "06:00", now: date("00:00:00"))
        #expect(schedule.decision(at: date("04:00:00")) == .start)
        #expect(schedule.end == date("06:00:00"))
    }

    @Test("waking after the window doesn't start at all")
    func wakingAfterWindow() {
        let schedule = window(start: "02:00", end: "06:00", now: date("00:00:00"))
        #expect(schedule.decision(at: date("08:00:00")) == .missed)
        #expect(schedule.decision(at: date("06:00:00")) == .missed)
    }

    @Test("with no End time, a late wake still starts")
    func lateWithoutEnd() {
        let schedule = window(start: "02:00", now: date("00:00:00"))
        #expect(schedule.decision(at: date("08:00:00")) == .start)
    }

    @Test("a fixed pair of moments can be given directly, as a Queue does")
    func fixedMoments() {
        let schedule = ScheduleWindow(start: date("10:05:00"), end: date("10:01:00"))
        #expect(schedule.decision(at: date("10:05:00")) == .missed)
    }
}

@Suite("Queue wait")
struct QueueWaitTests {
    private func start(_ hours: Int, _ minutes: Int, now: Date) -> Date? {
        QueueWait(hours: hours, minutes: minutes).startDate(after: now, calendar: utcCalendar)
    }

    @Test("no wait means no Start time")
    func noWait() {
        #expect(start(0, 0, now: date("10:00:00")) == nil)
    }

    @Test("it lands on a clock minute")
    func firstHalfOfMinute() {
        #expect(start(0, 1, now: date("10:00:20")) == date("10:01:00"))
        #expect(start(0, 1, now: date("10:00:30")) == date("10:01:00"))
    }

    @Test("past 30 seconds it adds a minute, so the wait is never much shorter than asked")
    func secondHalfOfMinute() {
        #expect(start(0, 1, now: date("10:00:31")) == date("10:02:00"))
    }

    @Test("hours count too")
    func hours() {
        #expect(start(1, 30, now: date("10:00:00")) == date("11:30:00"))
    }

    @Test("it can cross midnight")
    func midnight() {
        #expect(start(0, 5, now: date("23:58:00")) == tomorrow("00:03:00"))
        #expect(start(0, 1, now: date("23:59:40")) == tomorrow("00:01:00"))
    }
}
