import Foundation

/// Turns a date into the integer a planned meal is filed and queried under.
///
/// The key is `yyyymmdd` in the user's own calendar: 31 October 2026 is `20261031`.
///
/// Why an Int and not the `Date` itself. A planned meal belongs to a DAY, not to an
/// instant, and `Date` cannot express that — two meals on the same Tuesday differ by
/// whatever time of day each happened to be created with, so "fetch Tuesday" becomes a
/// half-open range comparison that has to be got exactly right at both ends, every time,
/// in every query. One off-by-one at the upper bound silently shows Wednesday's dinner on
/// Tuesday. An integer equality is not capable of that mistake.
///
/// It is also ordered and readable: `20261031 < 20261101` sorts correctly without a
/// calendar, a week is a range of seven keys, and the value means something when it shows
/// up in a debugger or a CloudKit dashboard, which `782179200.0` does not.
///
/// The cost, stated so nobody rediscovers it as a bug: the key is computed in the
/// calendar passed in, so a meal planned in one time zone keeps the day it was planned
/// for rather than shifting when the phone moves. That is the right behaviour for dinner
/// — Tuesday's dinner is Tuesday's wherever you are — but it does mean the key is not a
/// UTC instant and must never be treated as one.
enum CalendarKey {

    /// `yyyymmdd` for the day `date` falls on.
    static func dayKey(for date: Date, in calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        // Defaulting rather than force-unwrapping: these three are always present for a
        // Gregorian date, but a crash on the calendar screen is a bad way to find out
        // about a calendar that disagrees.
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return year * 10_000 + month * 100 + day
    }

    /// The first moment of the day a key names, or nil if the key is not a real date.
    /// Used to render a key back into something a date formatter can take.
    static func startOfDay(forKey key: Int, in calendar: Calendar = .current) -> Date? {
        guard key > 0 else { return nil }
        var parts = DateComponents()
        parts.year = key / 10_000
        parts.month = (key / 100) % 100
        parts.day = key % 100
        guard let month = parts.month, let day = parts.day,
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return calendar.date(from: parts)
    }

    /// Every day key from `start` to `end` inclusive, in order.
    ///
    /// Built by walking the calendar one day at a time rather than by arithmetic on the
    /// key, because `20261031 + 1` is `20261032`, which is not a date. Month ends and leap
    /// days are exactly where a plan week is most likely to be wrong.
    static func dayKeys(from start: Date, to end: Date, in calendar: Calendar = .current) -> [Int] {
        guard start <= end else { return [] }
        var keys: [Int] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        // A hard ceiling so a malformed interval cannot spin. Two years of days is far
        // more than any screen asks for, and returning a truncated list is better than
        // hanging the app.
        var guardRail = 0
        while cursor <= last && guardRail < 800 {
            keys.append(dayKey(for: cursor, in: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            guardRail += 1
        }
        return keys
    }

    /// The seven day keys of the week containing `date`.
    static func weekKeys(containing date: Date, in calendar: Calendar = .current) -> [Int] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return [dayKey(for: date, in: calendar)]
        }
        // `dateInterval` returns a half-open range whose end is the first moment of the
        // NEXT week. Passing that end straight in would yield eight keys and put next
        // Monday on this week's plan, so step back inside the interval first.
        let lastDay = week.end.addingTimeInterval(-1)
        return dayKeys(from: week.start, to: lastDay, in: calendar)
    }
}
