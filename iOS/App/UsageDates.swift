import Foundation

/// Local calendar boundaries, not fixed-length 24-hour arithmetic.
enum UsageDates {
    static func range(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -14, to: today)!
        return first...today
    }

    static func clamped(_ date: Date, now: Date, calendar: Calendar) -> Date {
        let days = range(now: now, calendar: calendar)
        return min(max(calendar.startOfDay(for: date), days.lowerBound), days.upperBound)
    }

    static func interval(for date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }
}
