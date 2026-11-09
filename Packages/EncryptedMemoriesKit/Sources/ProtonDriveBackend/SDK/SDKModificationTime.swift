import Foundation

/// The text form of a file's modification time at the Proton Drive SDK boundary: ISO 8601 with seconds and a UTC
/// offset, for example `2026-10-21T09:55:00.0000000+08:00`. The SDK rejects any other form on writes.
///
/// Both directions use the proleptic Gregorian calendar of the SDK's native core and its 100-nanosecond precision,
/// so the instant that crosses the boundary equals the one the earlier timestamp-based API carried.
enum SDKModificationTime {
    enum FormatError: Error, Equatable {
        /// The SDK accepts only the years 0001 through 9999.
        case outOfRange
    }

    /// Writes `date` in UTC (`Z`) with seven fractional digits.
    ///
    /// The fraction is the date rounded to the nearest nanosecond and then cut to 100-nanosecond ticks, which is the
    /// value the native core stored when it received the same date as a protobuf timestamp.
    static func string(from date: Date) throws -> String {
        let sinceReferenceDate = date.timeIntervalSinceReferenceDate
        guard sinceReferenceDate >= Self.earliestSecondSinceReferenceDate,
            sinceReferenceDate < Self.endSecondSinceReferenceDate
        else { throw FormatError.outOfRange }
        let wholeSeconds = Int64(sinceReferenceDate)
        let roundedNanoseconds = Int64(
            ((sinceReferenceDate - Double(wholeSeconds)) * Double(Self.nanosecondsPerSecond))
                .rounded(.toNearestOrAwayFromZero))
        let unixSeconds =
            wholeSeconds + Int64(Date.timeIntervalBetween1970AndReferenceDate)
            + Self.floorDivision(roundedNanoseconds, Self.nanosecondsPerSecond)
        let nanoseconds =
            roundedNanoseconds - Self.floorDivision(roundedNanoseconds, Self.nanosecondsPerSecond)
            * Self.nanosecondsPerSecond
        guard unixSeconds >= Self.earliestUnixSecond, unixSeconds < Self.endUnixSecond else {
            throw FormatError.outOfRange
        }
        let days = Self.floorDivision(unixSeconds, Self.secondsPerDay)
        let secondOfDay = unixSeconds - days * Self.secondsPerDay
        let civil = Self.civilDate(daysSince1970: days)
        return Self.digits(civil.year, 4) + "-" + Self.digits(civil.month, 2) + "-" + Self.digits(civil.day, 2)
            + "T" + Self.digits(secondOfDay / 3600, 2) + ":" + Self.digits(secondOfDay / 60 % 60, 2)
            + ":" + Self.digits(secondOfDay % 60, 2) + "." + Self.digits(nanoseconds / 100, 7) + "Z"
    }

    /// Reads the text the SDK reports. Returns nil for any other form instead of guessing a date.
    ///
    /// Accepted: `yyyy-MM-ddTHH:mm:ss`, an optional fraction of one to seven digits, then `Z` or `+hh:mm`/`-hh:mm`
    /// up to 14 hours. The result equals `seconds + nanos / 1e9` of the protobuf timestamp the earlier API returned.
    static func date(from text: String) -> Date? {
        var scanner = Scanner(Array(text.utf8))
        guard let year = scanner.number(4), year >= 1, scanner.take(UInt8(ascii: "-")),
            let month = scanner.number(2), (1...12).contains(month), scanner.take(UInt8(ascii: "-")),
            let day = scanner.number(2), day >= 1, day <= Self.daysInMonth(year: year, month: month),
            scanner.take(UInt8(ascii: "T")),
            let hour = scanner.number(2), hour <= 23, scanner.take(UInt8(ascii: ":")),
            let minute = scanner.number(2), minute <= 59, scanner.take(UInt8(ascii: ":")),
            let second = scanner.number(2), second <= 59
        else { return nil }
        var nanoseconds: Int64 = 0
        if scanner.take(UInt8(ascii: ".")) {
            var count = 0
            while let digit = scanner.digit() {
                count += 1
                guard count <= 7 else { return nil }
                nanoseconds = nanoseconds * 10 + digit
            }
            guard count > 0 else { return nil }
            for _ in count..<9 { nanoseconds *= 10 }
        }
        var offsetSeconds: Int64 = 0
        if !scanner.take(UInt8(ascii: "Z")) {
            let sign: Int64
            if scanner.take(UInt8(ascii: "+")) {
                sign = 1
            } else if scanner.take(UInt8(ascii: "-")) {
                sign = -1
            } else {
                return nil
            }
            guard let offsetHours = scanner.number(2), scanner.take(UInt8(ascii: ":")),
                let offsetMinutes = scanner.number(2), offsetMinutes <= 59,
                offsetHours * 60 + offsetMinutes <= 14 * 60
            else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        }
        guard scanner.isAtEnd else { return nil }
        let unixSeconds =
            Self.daysSince1970(year: year, month: month, day: day) * Self.secondsPerDay
            + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(
            timeIntervalSince1970: TimeInterval(unixSeconds)
                + TimeInterval(nanoseconds) / TimeInterval(Self.nanosecondsPerSecond))
    }

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000
    private static let secondsPerDay: Int64 = 86_400
    /// 0001-01-01T00:00:00Z and 10000-01-01T00:00:00Z, the limits of the native core's date type.
    private static let earliestUnixSecond: Int64 = -62_135_596_800
    private static let endUnixSecond: Int64 = 253_402_300_800
    private static let earliestSecondSinceReferenceDate =
        Double(earliestUnixSecond) - Date.timeIntervalBetween1970AndReferenceDate
    private static let endSecondSinceReferenceDate =
        Double(endUnixSecond) - Date.timeIntervalBetween1970AndReferenceDate

    private static func floorDivision(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static func isLeapYear(_ year: Int64) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`).
    private static func daysSince1970(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = floorDivision(shiftedYear, 400)
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `daysSince1970` (Howard Hinnant's `civil_from_days`).
    private static func civilDate(daysSince1970 days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = floorDivision(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func digits(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index == bytes.count }

        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func digit() -> Int64? {
            guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                return nil
            }
            defer { index += 1 }
            return Int64(bytes[index] - UInt8(ascii: "0"))
        }

        /// Exactly `count` ASCII digits.
        mutating func number(_ count: Int) -> Int64? {
            var value: Int64 = 0
            for _ in 0..<count {
                guard let digit = digit() else { return nil }
                value = value * 10 + digit
            }
            return value
        }
    }
}
