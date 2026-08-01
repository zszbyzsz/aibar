import SwiftUI

private func shortDate(_ isoDate: String) -> String {
    // isoDate is "yyyy-MM-dd"; the last 5 characters are already "MM-dd".
    String(isoDate.suffix(5))
}

/// Presentation policy for manually redeemable reset credits: distant credits
/// stay quiet alarm markers on their calendar day, while credits expiring
/// within ten days turn red and carry their remaining-day count. The date
/// itself is never spelled out — the marker's position in the heatmap is the
/// date.
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

/// Stable token anchors keep the same total at the same palette position while
/// interpolating between anchors removes the hard visual steps of fixed bands.
/// Exact totals remain available on hover.
enum UsageHeatmapScale {
    static let legendPositions: [Double] = [0, 0.25, 0.5, 0.75, 1]

    private static let anchors: [(tokens: Int, position: Double)] = [
        (0, 0),
        (100_000_000, 0.25),
        (500_000_000, 0.5),
        (1_000_000_000, 0.75),
        (5_000_000_000, 1),
    ]

    static func position(for tokens: Int) -> Double {
        guard tokens > 0 else { return 0 }
        for index in 1..<anchors.count where tokens <= anchors[index].tokens {
            let lower = anchors[index - 1]
            let upper = anchors[index]
            let fraction = Double(tokens - lower.tokens) / Double(upper.tokens - lower.tokens)
            return lower.position + (upper.position - lower.position) * fraction
        }
        return 1
    }
}

private struct HeatmapRGB {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    func dimmed(_ factor: Double) -> HeatmapRGB {
        HeatmapRGB(red: red * factor, green: green * factor, blue: blue * factor)
    }

    func interpolated(to other: HeatmapRGB, fraction: Double) -> HeatmapRGB {
        HeatmapRGB(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction
        )
    }
}

enum UsageMilestoneAdornment: Equatable {
    case none
    case dot
    case sparkle
    case pulsarCore
}

/// Visual rewards layered inside the token-driven heatmap cell. The 10B tier
/// is intentionally absent from the visible legend: discovering its pulsar
/// core is part of the reward.
enum UsageMilestone: Int, Comparable {
    case none
    case billion
    case fiveBillion
    case tenBillion

    static let billionThreshold = 1_000_000_000
    static let fiveBillionThreshold = 5_000_000_000
    static let tenBillionThreshold = 10_000_000_000
    static let visibleLegendTiers: [UsageMilestone] = [.billion, .fiveBillion]

    var adornment: UsageMilestoneAdornment {
        switch self {
        case .none: return .none
        case .billion: return .dot
        case .fiveBillion: return .sparkle
        case .tenBillion: return .pulsarCore
        }
    }

    static func level(for tokens: Int) -> UsageMilestone {
        switch tokens {
        case tenBillionThreshold...: return .tenBillion
        case fiveBillionThreshold...: return .fiveBillion
        case billionThreshold...: return .billion
        default: return .none
        }
    }

    static func < (lhs: UsageMilestone, rhs: UsageMilestone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct UsageMilestoneDecoration: View {
    let milestone: UsageMilestone

    private static let brightCyan = Color(red: 0.080, green: 0.910, blue: 1.000)
    private static let icyCore = Color(red: 0.830, green: 0.970, blue: 1.000)

    @ViewBuilder
    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch milestone.adornment {
            case .none:
                EmptyView()
            case .dot:
                Circle()
                    .fill(Self.brightCyan)
                    .frame(width: 3.5, height: 3.5)
                    .padding(3)
            case .sparkle:
                Image(systemName: "sparkle")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(Self.icyCore)
                    .padding(2.5)
            case .pulsarCore:
                ZStack {
                    Circle()
                        .stroke(Self.brightCyan.opacity(0.95), lineWidth: 1)
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Self.icyCore)
                        .frame(width: 4, height: 4)
                        .shadow(color: Self.brightCyan.opacity(0.9), radius: 1.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Guarantees every reward remains inside the 18pt heatmap square,
        // including the pulsar core's restrained inner shadow.
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    private static let heatmapPalette: [HeatmapRGB] = [
        HeatmapRGB(red: 0.275, green: 0.190, blue: 0.620),
        HeatmapRGB(red: 0.355, green: 0.315, blue: 0.900),
        HeatmapRGB(red: 0.120, green: 0.405, blue: 0.925),
        HeatmapRGB(red: 0.055, green: 0.620, blue: 0.930),
        HeatmapRGB(red: 0.080, green: 0.825, blue: 0.825),
    ]
    private static let resetUrgentColor = Color(red: 1.000, green: 0.280, blue: 0.340)
    private static let resetScheduledColor = Color(red: 1.000, green: 0.620, blue: 0.160)

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

    private static func heatmapRGB(at position: Double) -> HeatmapRGB {
        let clamped = min(1, max(0, position))
        let scaled = clamped * Double(heatmapPalette.count - 1)
        let lowerIndex = min(Int(scaled), heatmapPalette.count - 1)
        let upperIndex = min(lowerIndex + 1, heatmapPalette.count - 1)
        return heatmapPalette[lowerIndex].interpolated(
            to: heatmapPalette[upperIndex],
            fraction: scaled - Double(lowerIndex)
        )
    }

    private func cellFill(_ point: DailyPoint?) -> LinearGradient {
        guard let point else {
            return LinearGradient(
                colors: [.clear, .clear],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
        }
        guard point.tokens > 0 else {
            return LinearGradient(
                colors: [Color.notchRule, Color.notchRule],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
        }
        let rgb = Self.heatmapRGB(at: UsageHeatmapScale.position(for: point.tokens))
        return LinearGradient(
            colors: [rgb.dimmed(0.84).color, rgb.color],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    private func resetExpiries(for point: DailyPoint?) -> [Double] {
        guard let point else { return [] }
        return timeline.resetExpiriesByDate[point.date] ?? []
    }

    @ViewBuilder
    private func milestoneLegend(_ milestone: UsageMilestone, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.notchRule)
                .frame(width: 12, height: 12)
                .overlay(UsageMilestoneDecoration(milestone: milestone))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchMutedInk)
        }
    }

    /// Days left until an imminent expiry. Deliberately unlocalized: at this
    /// size a CJK glyph is unreadable, and the dashboard already uses the bare
    /// `d` suffix in both languages (`30d 窗口`).
    private static func daysLeftBadge(_ expiry: Double) -> String {
        "\(ResetExpiryUrgency.daysRemaining(expiry))d"
    }

    @ViewBuilder
    private func resetMarker(for expiries: [Double]) -> some View {
        if let imminent = expiries.first(where: { ResetExpiryUrgency.isDetailed($0) }) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Self.resetUrgentColor)
                .overlay(
                    Text(Self.daysLeftBadge(imminent))
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 1)
                )
                .accessibilityLabel(
                    L.resetExpiryWithinDays(lang, days: ResetExpiryUrgency.daysRemaining(imminent))
                )
        } else {
            Circle()
                .fill(Self.resetScheduledColor)
                .frame(width: Self.cellSize - 2, height: Self.cellSize - 2)
                .overlay(
                    Image(systemName: "alarm.fill")
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
                    let isUrgent = expiries.contains { ResetExpiryUrgency.isDetailed($0) }
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
                        .foregroundStyle(
                            expiries.isEmpty
                                ? Color.notchAccent
                                : (isUrgent ? Self.resetUrgentColor : Self.resetScheduledColor)
                        )
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
                                let milestone = UsageMilestone.level(for: point?.tokens ?? 0)
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(cellFill(point))
                                    if !expiries.isEmpty {
                                        resetMarker(for: expiries)
                                    } else if milestone != .none {
                                        UsageMilestoneDecoration(milestone: milestone)
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

            // Two short rows keep each symbol close to its meaning without
            // compressing every state into one long sentence. The 10B reward
            // remains deliberately undocumented as an easter egg.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(L.less(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: UsageHeatmapScale.legendPositions.map {
                                    Self.heatmapRGB(at: $0).color
                                },
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 68, height: 12)
                    Text(L.more(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    ForEach(UsageMilestone.visibleLegendTiers, id: \.self) { milestone in
                        milestoneLegend(milestone, label: milestone == .billion ? "1B+" : "5B+")
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.resetScheduledColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Image(systemName: "alarm.fill")
                                .font(.system(size: 6, weight: .heavy))
                                .foregroundStyle(Color.white)
                        )
                    Text(L.resetExpiryLegend(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.resetUrgentColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Text("3d")
                                .font(.system(size: 5.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.white)
                        )
                    Text(L.resetExpiryUrgentLegend(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.notchInk, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                    Text(L.today(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
