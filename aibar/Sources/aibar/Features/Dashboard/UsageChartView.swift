import SwiftUI

private func shortDate(_ isoDate: String) -> String {
    // isoDate is "yyyy-MM-dd"; the last 5 characters are already "MM-dd".
    String(isoDate.suffix(5))
}

/// GitHub-style calendar heatmap — a bar chart mixes "which day" (x position)
/// with "how much" (bar height) in a way that takes real scanning; a heatmap
/// drops position-as-magnitude and encodes intensity as color only, arranged
/// as full Mon–Sun weeks (oldest week on the left, columns running left to
/// right) so a week's rhythm reads as a shape at a glance instead of a
/// sequence of bar heights. Fixed at 7 rows regardless of how many weeks are
/// shown — width grows with more history instead of height, which is what
/// actually fills the card's row next to the session/weekly rings beside it
/// rather than just making the card taller. Hovering a cell (still inside the
/// dashboard's bounds, so it doesn't trigger auto-hide) surfaces the exact
/// date/cost/tokens, same as the old chart's tooltip.
struct UsageChartView: View {
    var daily: [DailyPoint]
    @State private var hovered: DailyPoint?
    @Environment(\.appLanguage) private var lang

    private static let cellSize: CGFloat = 18
    private static let cellSpacing: CGFloat = 2
    private static let legendRatios: [Double] = [0, 0.25, 0.5, 0.75, 1.0]

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

    /// `daily` is always a contiguous run of 30 days (see UsageScanner), so
    /// this only needs to pad the front with nils to land the first real day
    /// in its correct weekday column, then chunk into full Mon–Sun weeks.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let hovered {
                    Text(L.heatmapHover(lang, date: shortDate(hovered.date), cost: Formatting.moneyLabel(hovered.cost), tokens: Formatting.tokenLabel(hovered.tokens)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.notchAccent)
                } else {
                    Text(L.heatmapHint(lang, days: daily.count))
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
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(cellColor(point))
                                    .frame(width: Self.cellSize, height: Self.cellSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.notchAccent, lineWidth: point != nil && point?.id == hovered?.id ? 1.5 : 0)
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
                if let first = daily.first, let last = daily.last {
                    Text("· \(shortDate(first.date)) – \(shortDate(last.date))")
                        .font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
