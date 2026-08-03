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

    /// Three-significant-digit token label for the activity capsule's
    /// current/total context pair (`184K / 789M`). It is intentionally more
    /// compact than the dashboard formatter because both values must remain
    /// readable inside a single 32pt-high pill.
    static func contextTokenLabel(_ value: Int) -> String {
        let nonnegative = Double(max(0, value))
        let scaled: Double
        let suffix: String

        if nonnegative >= 1_000_000_000 {
            scaled = nonnegative / 1_000_000_000
            suffix = "B"
        } else if nonnegative >= 1_000_000 {
            scaled = nonnegative / 1_000_000
            suffix = "M"
        } else if nonnegative >= 1_000 {
            scaled = nonnegative / 1_000
            suffix = "K"
        } else {
            return "\(Int(nonnegative))"
        }

        let format = scaled >= 100 ? "%.0f" : (scaled >= 10 ? "%.1f" : "%.2f")
        return String(format: format, scaled) + suffix
    }

    static func groupedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, value))) ?? "0"
    }

    /// Compact token value with exactly four significant digits. The unit is
    /// selected independently of the precision, so large daily averages stay
    /// short while retaining useful differences (`1.303B`, `1.353M`, etc.).
    static func fourSignificantTokenLabel(_ value: Double) -> String {
        let nonnegative = max(0, value)
        guard nonnegative > 0 else { return "0" }

        let scaled: Double
        let suffix: String
        if nonnegative >= 1_000_000_000 {
            scaled = nonnegative / 1_000_000_000
            suffix = "B"
        } else if nonnegative >= 1_000_000 {
            scaled = nonnegative / 1_000_000
            suffix = "M"
        } else if nonnegative >= 1_000 {
            scaled = nonnegative / 1_000
            suffix = "K"
        } else {
            scaled = nonnegative
            suffix = ""
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 4
        formatter.maximumSignificantDigits = 4
        let number = formatter.string(from: NSNumber(value: scaled)) ?? "0"
        return number + suffix
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

    /// Deliberately coarser than `resetLabel`: the compact quota column only
    /// needs a single readable cadence value beside its Daily/Weekly title.
    static func compactRefreshLabel(
        _ resetsAt: Double?,
        lang: AppLanguage,
        now: Date = Date()
    ) -> String {
        guard let resetsAt else { return L.noLocalRecord(lang) }
        let remaining = Date(timeIntervalSince1970: resetsAt).timeIntervalSince(now)
        if remaining <= 0 { return L.waitingForSync(lang) }

        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        if minutes >= 1440 {
            return L.refreshesInDays(lang, days: Int((Double(minutes) / 1440).rounded(.up)))
        }
        if minutes >= 60 {
            return L.refreshesInHours(lang, hours: Int((Double(minutes) / 60).rounded(.up)))
        }
        return L.refreshesInMinutes(lang, minutes: minutes)
    }

    /// A larger, two-line quota readout puts the "remaining" label in the
    /// first line and this exact duration in the second. Week-long windows
    /// retain both day and hour precision; shorter windows stay focused on
    /// hours instead of introducing a noisy zero-day prefix.
    static func refreshRemainingDurationLabel(
        _ resetsAt: Double?,
        lang: AppLanguage,
        now: Date = Date()
    ) -> String {
        guard let resetsAt else { return L.noLocalRecord(lang) }
        let remaining = Date(timeIntervalSince1970: resetsAt).timeIntervalSince(now)
        if remaining <= 0 { return L.waitingForSync(lang) }

        let totalHours = max(1, Int((remaining / 3_600).rounded(.up)))
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 {
            return L.remainingDaysHours(lang, days: days, hours: hours)
        }
        return L.remainingHours(lang, hours: totalHours)
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
