import Foundation

/// Derives the Apple-Photos-style two-line center title for the viewer top bar.
///
/// Line one prefers location, then capture date/time, then filename, and finally a localized fallback.
/// Line two shows date/time with location when available; otherwise it shows the position.
///
/// Pure value type so it is unit-testable without any view layer.
public struct ViewerTitle: Equatable, Sendable {
    public let line1: String
    public let line2: String
    public let reservesLocationLine: Bool

    public init(line1: String, line2: String, reservesLocationLine: Bool = false) {
        self.line1 = line1
        self.line2 = line2
        self.reservesLocationLine = reservesLocationLine
    }
}

public enum ViewerTitleFormatter {
    /// - Parameters:
    ///   - captureDate: capture date/time, if known.
    ///   - index: zero-based index of the current item in the library.
    ///   - total: total item count.
    ///   - locationName: reverse-geocoded POI/location name, if already available (never blocks on it). A name of
    ///     whitespace alone counts as no name.
    ///   - filename: original filename, used only as a date-less fallback.
    ///   - locale: user/app locale - drives date wording ("um") and the "von"/"of" connector.
    public static func make(
        captureDate: Date?,
        index: Int,
        total: Int,
        locationName: String? = nil,
        locationIsResolving: Bool = false,
        filename: String? = nil,
        locale: Locale = .current
    ) -> ViewerTitle {
        let position = positionString(index: index, total: total, locale: locale)
        let dateTime = captureDate.map { dateTimeString($0, locale: locale) }

        if let locationName = PlaceNameText.displayable(locationName) {
            let second = dateTime.map { "\($0) · \(position)" } ?? position
            return ViewerTitle(line1: locationName, line2: second)
        }
        if locationIsResolving {
            let second = dateTime.map { "\($0) · \(position)" } ?? position
            return ViewerTitle(line1: " ", line2: second, reservesLocationLine: true)
        }
        if let dateTime {
            return ViewerTitle(line1: dateTime, line2: position)
        }
        if let filename, !filename.isEmpty {
            return ViewerTitle(line1: filename, line2: position)
        }
        // Localized via the same `locale` parameter the rest of this formatter honors (kept locale-driven
        // rather than bundle-driven so the formatter stays deterministically unit-testable per locale).
        return ViewerTitle(line1: isGerman(locale) ? "Foto" : "Photo", line2: position)
    }

    /// "17. Juni 2026 um 16:53:58" for German locales, otherwise the locale's natural date+time string.
    static func dateTimeString(_ date: Date, locale: Locale) -> String {
        let datePart = date.formatted(.dateTime.day().month(.wide).year().locale(locale))
        let timePart = date.formatted(.dateTime.hour().minute().second().locale(locale))
        if isGerman(locale) {
            return "\(datePart) um \(timePart)"
        }
        return "\(datePart) · \(timePart)"
    }

    /// "4.454 von 35.666" (German) / "4,454 of 35,666" (English). Index is presented 1-based.
    static func positionString(index: Int, total: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        let current = formatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
        let count = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
        let connector = isGerman(locale) ? "von" : "of"
        return "\(current) \(connector) \(count)"
    }

    private static func isGerman(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "de"
    }
}
