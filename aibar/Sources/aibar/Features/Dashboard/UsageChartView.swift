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

/// Maps authoritative daily token totals to heatmap intensity. Square-root
/// scaling keeps the ordering strictly tied to token volume while preventing
/// one unusually large day from making every other active day look empty.
/// This is a presentation transform only: hover text continues to show the
/// exact token count.
enum UsageHeatmapIntensity {
    static func ratio(tokens: Int, maximum: Int) -> Double {
        guard tokens > 0, maximum > 0 else { return 0 }
        let linearRatio = min(1, Double(tokens) / Double(maximum))
        return linearRatio.squareRoot()
    }
}

/// Visual rewards layered on top of the token-driven heatmap color. The 10B
/// tier is intentionally absent from the visible legend: discovering its
/// double ring and glint is part of the reward.
enum UsageMilestone: Int, Comparable {
    case none
    case billion
    case fiveBillion
    case tenBillion

    static let billionThreshold = 1_000_000_000
    static let fiveBillionThreshold = 5_000_000_000
    static let tenBillionThreshold = 10_000_000_000

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

struct UsageMilestoneRun: Identifiable, Equatable {
    let startRow: Int
    let endRow: Int
    let milestone: UsageMilestone

    var id: Int { startRow }
    var rowCount: Int { endRow - startRow + 1 }
}

/// Calendar days run vertically inside each week column. Adjacent milestone
/// cells therefore become one framed streak, using the strongest reward found
/// in that streak. A week turn starts a new visual group because Sunday and
/// Monday are not adjacent on screen.
enum UsageMilestoneGrouping {
    static func runs(in week: [DailyPoint?]) -> [UsageMilestoneRun] {
        var result: [UsageMilestoneRun] = []
        var startRow: Int?
        var strongest = UsageMilestone.none

        func finish(at endRow: Int) {
            guard let startRow else { return }
            result.append(
                UsageMilestoneRun(startRow: startRow, endRow: endRow, milestone: strongest)
            )
        }

        for row in week.indices {
            let milestone = UsageMilestone.level(for: week[row]?.tokens ?? 0)
            if milestone == .none {
                if startRow != nil { finish(at: row - 1) }
                startRow = nil
                strongest = .none
            } else {
                if startRow == nil { startRow = row }
                strongest = max(strongest, milestone)
            }
        }
        if startRow != nil { finish(at: week.count - 1) }
        return result
    }
}

/// Four short strokes preserve the square's heatmap fill while giving high-
/// usage days a crisp, celebratory frame.
private struct MilestoneCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let segment = min(rect.width, rect.height) * 0.28
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + segment))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + segment, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - segment, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + segment))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - segment))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - segment, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + segment, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - segment))

        return path
    }
}

private struct UsageMilestoneDecoration: View {
    let milestone: UsageMilestone

    private static let cornerBlue = Color(red: 0.180, green: 0.490, blue: 1.000)
    private static let brightCyan = Color(red: 0.080, green: 0.910, blue: 1.000)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if milestone >= .fiveBillion {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Self.brightCyan, lineWidth: milestone == .tenBillion ? 1.2 : 1.5)
                    .padding(-2)
                    .shadow(color: Self.brightCyan.opacity(0.75), radius: 3)
            }

            if milestone == .tenBillion {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Self.brightCyan.opacity(0.85), lineWidth: 1)
                    .padding(-4)

                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color(red: 0.520, green: 0.890, blue: 1.000))
                    .shadow(color: Self.brightCyan, radius: 3)
                    .offset(x: 4, y: -4)
            } else {
                MilestoneCorners()
                    .stroke(
                        milestone == .fiveBillion ? Self.brightCyan : Self.cornerBlue,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .padding(-1)
                    .shadow(
                        color: (milestone == .fiveBillion ? Self.brightCyan : Self.cornerBlue).opacity(0.75),
                        radius: milestone == .fiveBillion ? 3 : 2
                    )
            }
        }
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
    private static let legendRatios: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
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

    private var maxTokens: Int { daily.map(\.tokens).max() ?? 0 }

    private func cellColor(_ point: DailyPoint?, ratioOverride: Double? = nil) -> Color {
        if let ratioOverride { return ratioOverride <= 0 ? Color.notchRule : Color.notchAccent.opacity(0.28 + 0.72 * ratioOverride) }
        guard let point else { return .clear }
        guard point.tokens > 0 else { return Color.notchRule }
        let intensity = UsageHeatmapIntensity.ratio(tokens: point.tokens, maximum: maxTokens)
        return Color.notchAccent.opacity(0.28 + 0.72 * intensity)
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
                        let milestoneRuns = UsageMilestoneGrouping.runs(in: weeks[col])
                        ZStack(alignment: .topLeading) {
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

                            ForEach(milestoneRuns) { run in
                                UsageMilestoneDecoration(milestone: run.milestone)
                                    .frame(
                                        width: Self.cellSize,
                                        height: CGFloat(run.rowCount) * Self.cellSize
                                            + CGFloat(run.rowCount - 1) * Self.cellSpacing
                                    )
                                    .offset(
                                        y: CGFloat(run.startRow) * (Self.cellSize + Self.cellSpacing)
                                    )
                                    .zIndex(1)
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
                    ForEach(Self.legendRatios, id: \.self) { ratio in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cellColor(nil, ratioOverride: ratio))
                            .frame(width: 12, height: 12)
                    }
                    Text(L.more(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    milestoneLegend(.billion, label: "1B+")
                    milestoneLegend(.fiveBillion, label: "5B+")
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
