import SwiftUI

private func shortDate(_ isoDate: String) -> String {
    // isoDate is "yyyy-MM-dd"; the last 5 characters are already "MM-dd".
    String(isoDate.suffix(5))
}

/// Presentation policy for every manually redeemable reset credit. Credits
/// farther than ten days out use the quiet orange alarm; each credit entering
/// the ten-day window becomes a red day-count badge. These markers remain
/// independent from the subscription-end and weekly-refresh outlines.
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

/// A fixed-size 154-day (22-week) window whose right edge advances to the end
/// of the furthest marker's calendar week. Starting on Monday and ending on
/// Sunday means every displayed position is a real day — no transparent
/// alignment cells at either edge. Every reset credit keeps its own date; the
/// subscription end and next weekly reset remain singular account boundaries.
struct UsageTimeline {
    static let weekCount = 22
    static let dayCount = weekCount * 7

    let points: [DailyPoint]
    let resetExpiriesByDate: [String: [Double]]
    let todayKey: String
    let subscriptionEndKey: String?
    let weeklyResetKey: String?

    init(
        daily: [DailyPoint],
        resetCredits: RateLimitResetCredits?,
        weeklyResetAt: Double?,
        subscriptionEndsAt: Date?,
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
        let weeklyResetDay = weeklyResetAt.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: $0))
        }
        let subscriptionEndDay = subscriptionEndsAt.map(calendar.startOfDay(for:))
        let resetExpiries = resetCredits?.expiresAt ?? []
        let resetExpiryDays = resetExpiries.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: $0))
        }
        weeklyResetKey = weeklyResetDay.map(key(for:))
        subscriptionEndKey = subscriptionEndDay.map(key(for:))
        let boundaryEnd = ([today, weeklyResetDay, subscriptionEndDay] + resetExpiryDays)
            .compactMap { $0 }
            .max() ?? today
        // Calendar weekday uses 1 = Sunday ... 7 = Saturday. Advancing the
        // boundary to Sunday keeps the visible matrix at an exact whole-week
        // width while still guaranteeing every account marker is included.
        let daysUntilSunday = (8 - calendar.component(.weekday, from: boundaryEnd)) % 7
        let end = calendar.date(byAdding: .day, value: daysUntilSunday, to: boundaryEnd) ?? boundaryEnd
        let start = calendar.date(byAdding: .day, value: -(Self.dayCount - 1), to: end) ?? end
        let existing = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })

        points = (0..<Self.dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let dateKey = key(for: date)
            return existing[dateKey] ?? DailyPoint(date: dateKey, tokens: 0, cost: 0)
        }

        var grouped: [String: [Double]] = [:]
        for expiry in resetExpiries {
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
/// sequence of bar heights. Fixed at 7 rows across a dynamic 154-day window —
/// width grows with more history instead of height, which is what
/// actually fills the card's row next to the session/weekly rings beside it
/// rather than just making the card taller. Hovering a cell (still inside the
/// dashboard's bounds, so it doesn't trigger auto-hide) surfaces the exact
/// date/cost/tokens, same as the old chart's tooltip.
struct UsageChartView: View {
    var timeline: UsageTimeline
    var onStatusChange: (String?) -> Void = { _ in }
    @State private var hovered: DailyPoint?
    @Environment(\.appLanguage) private var lang

    private static let cellSize: CGFloat = 17
    private static let rowSpacing: CGFloat = 1.5
    private static let minimumWeekSpacing: CGFloat = 2
    private static let weekdayLabelWidth: CGFloat = 10
    private static let weekdayGridSpacing: CGFloat = 6
    private static let gridHeight = cellSize * 7 + rowSpacing * 6
    private static let heatmapPalette: [HeatmapRGB] = [
        HeatmapRGB(red: 0.075, green: 0.145, blue: 0.255),
        HeatmapRGB(red: 0.035, green: 0.215, blue: 0.495),
        HeatmapRGB(red: 0.025, green: 0.365, blue: 0.785),
        HeatmapRGB(red: 0.030, green: 0.510, blue: 1.000),
        HeatmapRGB(red: 0.040, green: 0.690, blue: 0.980),
    ]
    private static let endColor = Color(red: 1.000, green: 0.280, blue: 0.340)
    private static let weeklyResetColor = Color(red: 1.000, green: 0.720, blue: 0.160)
    private static let resetUrgentColor = Color(red: 1.000, green: 0.280, blue: 0.340)
    private static let resetScheduledColor = Color(red: 1.000, green: 0.620, blue: 0.160)

    private var daily: [DailyPoint] { timeline.points }

    private func statusText(for point: DailyPoint) -> String {
        let markers = markerLabels(for: point)
        let expiries = resetExpiries(for: point)
        if !expiries.isEmpty {
            return L.heatmapResetHover(
                lang,
                date: shortDate(point.date),
                count: expiries.count,
                times: expiries.map { Formatting.compactTimeLabel($0) }.joined(separator: ", "),
                additionalMarkers: markers
            )
        }
        if !markers.isEmpty {
            return L.heatmapMarkerHover(
                lang,
                date: shortDate(point.date),
                markers: markers.joined(separator: " · ")
            )
        }
        return L.heatmapHover(
            lang,
            date: shortDate(point.date),
            cost: Formatting.moneyLabel(point.cost),
            tokens: Formatting.tokenLabel(point.tokens)
        )
    }

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

    /// Distribute only the horizontal inter-week space. Keeping cell height
    /// fixed makes the card more compact while still carrying the final week
    /// exactly to the legend's trailing edge at every dashboard width.
    private func weekSpacing(for totalWidth: CGFloat) -> CGFloat {
        let gridWidth = max(
            0,
            totalWidth - Self.weekdayLabelWidth - Self.weekdayGridSpacing
        )
        let gapCount = max(1, weeks.count - 1)
        let fitted = (
            gridWidth - CGFloat(weeks.count) * Self.cellSize
        ) / CGFloat(gapCount)
        return max(Self.minimumWeekSpacing, fitted)
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

    private enum LegendMarker {
        case scheduledReset
        case urgentReset
        case today
        case subscriptionEnd
        case weeklyReset
    }

    private struct LegendSwatch: View {
        var marker: LegendMarker

        @ViewBuilder
        var body: some View {
            switch marker {
            case .scheduledReset:
                Circle()
                    .fill(UsageChartView.resetScheduledColor)
                    .overlay(
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 5.5, weight: .heavy))
                            .foregroundStyle(Color.white)
                    )
            case .urgentReset:
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(UsageChartView.resetUrgentColor)
                    .overlay(
                        Text("3d")
                            .font(.system(size: 5.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.white)
                    )
            case .today:
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(Color.notchInk, lineWidth: 1.5)
            case .subscriptionEnd:
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(UsageChartView.endColor, lineWidth: 2)
                    .shadow(color: UsageChartView.endColor.opacity(0.35), radius: 1)
            case .weeklyReset:
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(UsageChartView.weeklyResetColor, lineWidth: 2)
            }
        }
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

    private func markerLegend(_ marker: LegendMarker, label: String) -> some View {
        HStack(spacing: 4) {
            LegendSwatch(marker: marker)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Color.notchMutedInk)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactLegend: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(L.less(lang))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Color.notchMutedInk)
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
                        .frame(width: 62, height: 10)
                    Text(L.more(lang))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Color.notchMutedInk)
                }

                HStack(spacing: 9) {
                    ForEach(UsageMilestone.visibleLegendTiers, id: \.self) { milestone in
                        milestoneLegend(milestone, label: milestone == .billion ? "1B+" : "5B+")
                    }
                }
            }

            Rectangle()
                .fill(Color.notchRule)
                .frame(width: 1, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    markerLegend(.scheduledReset, label: L.resetExpiryLegend(lang))
                    markerLegend(.urgentReset, label: L.resetExpiryUrgentLegend(lang))
                }
                HStack(spacing: 9) {
                    markerLegend(.today, label: L.today(lang))
                    markerLegend(.subscriptionEnd, label: L.subscriptionEndLegend(lang))
                    markerLegend(.weeklyReset, label: L.weeklyRefreshLegend(lang))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func markerLabels(for point: DailyPoint) -> [String] {
        var labels: [String] = []
        if point.date == timeline.subscriptionEndKey { labels.append(L.subscriptionEndLegend(lang)) }
        if point.date == timeline.weeklyResetKey { labels.append(L.weeklyRefreshLegend(lang)) }
        return labels
    }

    /// Days left until an imminent reset credit expires. The compact `d`
    /// suffix stays legible inside a 17pt heatmap cell in both languages.
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
                .padding(1)
                .shadow(color: Self.resetUrgentColor.opacity(0.4), radius: 1.5)
        } else {
            Circle()
                .fill(Self.resetScheduledColor)
                .frame(width: Self.cellSize - 4, height: Self.cellSize - 4)
                .overlay(
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.white)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75)
                )
                .shadow(color: Self.resetScheduledColor.opacity(0.32), radius: 1)
                .accessibilityLabel(L.resetExpiryLegend(lang))
        }
    }

    @ViewBuilder
    private func markerBorders(for point: DailyPoint?) -> some View {
        if let point {
            let isEnd = point.date == timeline.subscriptionEndKey
            let isWeeklyReset = point.date == timeline.weeklyResetKey
            if isEnd {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Self.endColor, lineWidth: 2.5)
                    .shadow(color: Self.endColor.opacity(0.55), radius: 2)
                    .accessibilityLabel(L.subscriptionEndLegend(lang))
            }
            if isWeeklyReset {
                RoundedRectangle(cornerRadius: isEnd ? 2.5 : 4)
                    .strokeBorder(Self.weeklyResetColor, lineWidth: isEnd ? 1.5 : 2.5)
                    .padding(isEnd ? 3 : 0)
                    .shadow(color: Self.weeklyResetColor.opacity(0.45), radius: isEnd ? 0 : 1.5)
                    .accessibilityLabel(L.weeklyRefreshLegend(lang))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Weekday labels as a leading column (rows, not a header row) now
            // that weeks run left to right — each label lines up with its own
            // row across every week-column below it.
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: Self.weekdayGridSpacing) {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(Array(L.weekdayLabels(lang).enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundStyle(Color.notchMutedInk)
                                .frame(
                                    width: Self.weekdayLabelWidth,
                                    height: Self.cellSize,
                                    alignment: .trailing
                                )
                        }
                    }

                    HStack(spacing: weekSpacing(for: proxy.size.width)) {
                        ForEach(weeks.indices, id: \.self) { col in
                            VStack(spacing: Self.rowSpacing) {
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
                                        .overlay(markerBorders(for: point))
                                        .onHover { isHovering in
                                            guard let point else { return }
                                            if isHovering {
                                                hovered = point
                                                onStatusChange(statusText(for: point))
                                            } else if hovered?.id == point.id {
                                                hovered = nil
                                                onStatusChange(nil)
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: Self.gridHeight)

            // One quiet legend surface turns the scale, rewards, and account
            // boundaries into a single visual system. The 10B reward remains
            // deliberately undocumented as an easter egg.
            compactLegend
        }
        .onChange(of: lang) { _ in
            onStatusChange(hovered.map(statusText(for:)))
        }
        .onDisappear { onStatusChange(nil) }
    }
}
