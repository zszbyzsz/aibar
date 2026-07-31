import SwiftUI

private func shortDate(_ isoDate: String) -> String {
    // isoDate is "yyyy-MM-dd"; the last 5 characters are already "MM-dd".
    String(isoDate.suffix(5))
}

/// Presentation policy for manually redeemable reset credits: distant credits
/// remain quiet calendar markers, while credits expiring within ten days carry
/// their exact expiry time and an urgency color.
enum ResetExpiryUrgency {
    static let detailedWindow: TimeInterval = 10 * 86_400

    static func isDetailed(_ expiry: Double, now: Date = Date()) -> Bool {
        let remaining = Date(timeIntervalSince1970: expiry).timeIntervalSince(now)
        return remaining >= 0 && remaining <= detailedWindow
    }

    static func daysRemaining(_ expiry: Double, now: Date = Date()) -> Int {
        let remaining = Date(timeIntervalSince1970: expiry).timeIntervalSince(now)
        return max(0, Int(ceil(remaining / 86_400)))
    }
}

/// A fixed-size 90-day window whose right edge advances to the furthest known
/// Full reset expiry. With no reset it ends today; with an expiry 13 days out,
/// for example, it naturally shows 76 historical days, today, and 13 future
/// days. This keeps the grid stable while making expiry dates real positions
/// on the same calendar rather than detached labels.
struct UsageTimeline {
    static let dayCount = 90

    let points: [DailyPoint]
    let resetExpiriesByDate: [String: [Double]]
    let todayKey: String

    init(
        daily: [DailyPoint],
        resetCredits: RateLimitResetCredits?,
        now: Date = Date(),
        calendar requestedCalendar: Calendar = .current
    ) {
        var calendar = requestedCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        func key(for date: Date) -> String { formatter.string(from: date) }

        let today = calendar.startOfDay(for: now)
        todayKey = key(for: today)
        let expiries = resetCredits?.expiresAt ?? []
        let furthestExpiryDay = expiries
            .map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) }
            .max()
        let end = max(today, furthestExpiryDay ?? today)
        let start = calendar.date(byAdding: .day, value: -(Self.dayCount - 1), to: end) ?? end
        let existing = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })

        points = (0..<Self.dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let dateKey = key(for: date)
            return existing[dateKey] ?? DailyPoint(date: dateKey, tokens: 0, cost: 0)
        }

        var grouped: [String: [Double]] = [:]
        for expiry in expiries {
            grouped[key(for: Date(timeIntervalSince1970: expiry)), default: []].append(expiry)
        }
        resetExpiriesByDate = grouped.mapValues { $0.sorted() }
    }
}

/// GitHub-style calendar heatmap — a bar chart mixes "which day" (x position)
/// with "how much" (bar height) in a way that takes real scanning; a heatmap
/// drops position-as-magnitude and encodes intensity as color only, arranged
/// as full Mon–Sun weeks (oldest week on the left, columns running left to
/// right) so a week's rhythm reads as a shape at a glance instead of a
/// sequence of bar heights. Fixed at 7 rows across a dynamic 90-day window —
/// width grows with more history instead of height, which is what
/// actually fills the card's row next to the session/weekly rings beside it
/// rather than just making the card taller. Hovering a cell (still inside the
/// dashboard's bounds, so it doesn't trigger auto-hide) surfaces the exact
/// date/cost/tokens, same as the old chart's tooltip.
struct UsageChartView: View {
    var timeline: UsageTimeline
    @State private var hovered: DailyPoint?
    @Environment(\.appLanguage) private var lang

    private static let cellSize: CGFloat = 18
    private static let cellSpacing: CGFloat = 2
    private static let legendRatios: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
    private static let resetColor = Color(red: 1.000, green: 0.280, blue: 0.340)
    private static let resetSoonColor = Color(red: 1.000, green: 0.620, blue: 0.160)

    private var daily: [DailyPoint] { timeline.points }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Monday-indexed weekday (0 = Mon ... 6 = Sun) for grid column alignment.
    private static func mondayIndex(_ isoDate: String) -> Int {
        guard let date = isoFormatter.date(from: isoDate) else { return 0 }
        let sundayIndexed = Calendar.current.component(.weekday, from: date) // 1 = Sun ... 7 = Sat
        return (sundayIndexed + 5) % 7
    }

    /// The timeline is contiguous, so this only pads the front with nils to
    /// land its first real day in the correct weekday column, then chunks it
    /// into full Mon–Sun weeks.
    private var weeks: [[DailyPoint?]] {
        guard let first = daily.first else { return [] }
        var cells: [DailyPoint?] = Array(repeating: nil, count: Self.mondayIndex(first.date))
        cells.append(contentsOf: daily.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private var maxCost: Double { max(daily.map(\.cost).max() ?? 0, 0.01) }

    private func cellColor(_ point: DailyPoint?, ratioOverride: Double? = nil) -> Color {
        if let ratioOverride { return ratioOverride <= 0 ? Color.notchRule : Color.notchAccent.opacity(0.28 + 0.72 * ratioOverride) }
        guard let point else { return .clear }
        // A day can have real token activity priced at exactly $0 (an unpriced
        // or free model) — that must still read as "used a little", not fall
        // back to the same blank tint as a day with no activity at all.
        guard point.cost > 0 || point.tokens > 0 else { return Color.notchRule }
        return Color.notchAccent.opacity(0.28 + 0.72 * (point.cost / maxCost))
    }

    private func resetExpiries(for point: DailyPoint?) -> [Double] {
        guard let point else { return [] }
        return timeline.resetExpiriesByDate[point.date] ?? []
    }

    private var expiringSoon: [Double] {
        timeline.resetExpiriesByDate.values
            .flatMap { $0 }
            .filter { ResetExpiryUrgency.isDetailed($0) }
            .sorted()
    }

    private func urgencyColor(for expiry: Double) -> Color {
        switch ResetExpiryUrgency.daysRemaining(expiry) {
        case 0...1: return Self.resetColor
        case 2...3: return Color(red: 1.000, green: 0.460, blue: 0.180)
        default: return Self.resetSoonColor
        }
    }

    @ViewBuilder
    private func resetMarker(for expiries: [Double]) -> some View {
        if let imminent = expiries.first(where: { ResetExpiryUrgency.isDetailed($0) }) {
            RoundedRectangle(cornerRadius: 4)
                .fill(urgencyColor(for: imminent))
                .overlay(
                    Text(Formatting.compactTimeLabel(imminent))
                        .font(.system(size: 5.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 1)
                )
                .accessibilityLabel(
                    "\(L.resetExpiresSoon(lang)): \(Formatting.compactTimeLabel(imminent)), \(L.resetExpiryWithinDays(lang, days: ResetExpiryUrgency.daysRemaining(imminent)))"
                )
        } else {
            Circle()
                .fill(Self.resetColor)
                .frame(width: Self.cellSize - 2, height: Self.cellSize - 2)
                .overlay(
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                )
                .accessibilityLabel(L.resetExpiryLegend(lang))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let hovered {
                    let expiries = resetExpiries(for: hovered)
                    Text(
                        expiries.isEmpty
                            ? L.heatmapHover(lang, date: shortDate(hovered.date), cost: Formatting.moneyLabel(hovered.cost), tokens: Formatting.tokenLabel(hovered.tokens))
                            : L.heatmapResetHover(
                                lang,
                                date: shortDate(hovered.date),
                                count: expiries.count,
                                times: expiries.map { Formatting.compactTimeLabel($0) }.joined(separator: ", ")
                            )
                    )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(expiries.isEmpty ? Color.notchAccent : Self.resetColor)
                } else {
                    Text(L.heatmapTimelineHint(lang, days: daily.count))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.notchMutedInk)
                }
                Spacer()
            }
            .frame(height: 14)

            // Weekday labels as a leading column (rows, not a header row) now
            // that weeks run left to right — each label lines up with its own
            // row across every week-column below it.
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: Self.cellSpacing) {
                    ForEach(Array(L.weekdayLabels(lang).enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(Color.notchMutedInk)
                            .frame(width: 10, height: Self.cellSize, alignment: .trailing)
                    }
                }

                HStack(spacing: Self.cellSpacing) {
                    ForEach(weeks.indices, id: \.self) { col in
                        VStack(spacing: Self.cellSpacing) {
                            ForEach(0..<7, id: \.self) { row in
                                let point = weeks[col][row]
                                let expiries = resetExpiries(for: point)
                                let isToday = point?.date == timeline.todayKey
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(cellColor(point))
                                    if !expiries.isEmpty {
                                        resetMarker(for: expiries)
                                    }
                                }
                                    .frame(width: Self.cellSize, height: Self.cellSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(
                                                isToday
                                                    ? Color.notchInk
                                                    : (point != nil && point?.id == hovered?.id ? Color.notchAccent : Color.clear),
                                                lineWidth: isToday ? 2 : 1.5
                                            )
                                    )
                                    .onHover { isHovering in
                                        guard let point else { return }
                                        hovered = isHovering ? point : (hovered?.id == point.id ? nil : hovered)
                                    }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            // Below the grid rather than beside it — freed from competing for
            // width with the week columns above, and it's a natural width-only
            // row now that the grid's height no longer scales with history.
            HStack(spacing: 4) {
                Text(L.less(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                ForEach(Self.legendRatios, id: \.self) { ratio in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(cellColor(nil, ratioOverride: ratio))
                        .frame(width: 12, height: 12)
                }
                Text(L.more(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                Circle()
                    .fill(Self.resetColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(Color.white)
                    )
                Text(L.resetExpiryLegend(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.resetSoonColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "clock.fill")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(Color.white)
                    )
                Text(L.resetExpiresSoon(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                if let first = daily.first, let last = daily.last {
                    Text("· \(shortDate(first.date)) – \(shortDate(last.date))")
                        .font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                }
                Spacer(minLength: 0)
            }

            if !expiringSoon.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.resetExpiresSoon(lang))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Self.resetSoonColor)

                    ForEach(expiringSoon, id: \.self) { expiry in
                        let days = ResetExpiryUrgency.daysRemaining(expiry)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(urgencyColor(for: expiry))
                                .frame(width: 6, height: 6)
                            Text("\(shortDate(Self.isoFormatter.string(from: Date(timeIntervalSince1970: expiry)))) \(Formatting.compactTimeLabel(expiry))")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.notchInk)
                            Text(L.resetExpiryWithinDays(lang, days: days))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(urgencyColor(for: expiry))
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .contain)
            }
        }
    }
}
