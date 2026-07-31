import Foundation

private let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let isoPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

enum Formatting {
    /// Codex logs mix ISO-8601 timestamps with and without fractional seconds;
    /// this is the one place that reconciles both formats.
    static func parseISODate(_ value: String) -> Date? {
        isoWithFraction.date(from: value) ?? isoPlain.date(from: value)
    }

    static func isoTimestamp(from date: Date) -> String {
        isoWithFraction.string(from: date)
    }

    static func tokenLabel(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return "\(Int((v / 1_000).rounded()))K" }
        return "\(value)"
    }

    static func moneyLabel(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    /// A reset time already in the past just means the window rolled over since the
    /// last local event that reported it — say so rather than implying an imminent
    /// reset that, in fact, already happened.
    static func resetLabel(_ resetsAt: Double?, lang: AppLanguage) -> String {
        guard let resetsAt else { return L.noLocalRecord(lang) }
        let remaining = Date(timeIntervalSince1970: resetsAt).timeIntervalSinceNow
        if remaining <= 0 { return L.waitingForSync(lang) }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes >= 1440 {
            return L.resetsInDaysHours(lang, days: minutes / 1440, hours: (minutes % 1440) / 60)
        }
        if minutes >= 60 {
            return L.resetsInHoursMinutes(lang, hours: minutes / 60, minutes: minutes % 60)
        }
        return L.resetsInMinutes(lang, minutes: minutes)
    }

    /// The date itself is encoded by the reset's position in the heatmap; its
    /// hover detail therefore needs only the local wall-clock time.
    static func compactTimeLabel(
        _ timestamp: Double,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    /// Splits an elapsed-seconds count into hours/minutes — the one place
    /// this arithmetic lives, shared by every compact duration label instead
    /// of each call site re-deriving `minutes / 60` / `minutes % 60` on its own.
    static func hoursAndMinutes(fromSeconds seconds: Int) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(0, seconds) / 60
        return (totalMinutes / 60, totalMinutes % 60)
    }

    static func updatedAtLabel(_ date: Date, lang: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return L.updatedAt(lang, time: formatter.string(from: date))
    }
}
