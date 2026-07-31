import SwiftUI

/// The static "poster" rendered for `ShareLink` — a condensed snapshot of the
/// dashboard's key numbers, laid out and colored to match the live dashboard
/// but sized and paced for a single still image rather than a scrollable
/// panel. Kept entirely separate from `DashboardView` because the live cards
/// lean on animation (ring water fill, count-up numerals, hover state) that
/// has no meaning in a one-shot `ImageRenderer` snapshot — every value here
/// is drawn once, already in its final state.
///
/// Laid out taller and more spaced-out than a dashboard card on purpose —
/// this is the one view in the app whose entire job is to look good sitting
/// alone in a tweet or a chat thread, not to pack information densely into a
/// hover panel.
struct ShareCardView: View {
    var data: UsagePayload
    var provider: UsageProvider
    var lang: AppLanguage
    var style: ShareCardStyle = .midnight

    static let size = CGSize(width: 430, height: 700)

    private var weeklyLabel: String { L.weeklyLabel(lang, isMonthly: data.weeklyKind == "monthly") }
    private var recentDaily: [DailyPoint] { Array(data.daily.suffix(14)) }
    private var peakCost: Double { data.daily.map(\.cost).max() ?? 0 }

    private var generatedDateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: data.generatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Rectangle().fill(style.rule).frame(height: 1)
            hero
            statStrip
            quotaCard
            trendCard
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(cardBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(
                    LinearGradient(colors: [style.accent, style.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                Image(systemName: "cpu.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(style.badgeIcon)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.shareTitle(lang, provider: provider.title))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(style.ink)
                Text(L.planSessions(lang, plan: data.plan, count: data.sessionFileCount))
                    .font(.system(size: 10.5))
                    .foregroundStyle(style.mutedInk)
            }
            Spacer(minLength: 0)
        }
    }

    /// The card's one big flex number — given the most vertical room and the
    /// only gradient-filled type on the card, so it's unmistakably the first
    /// thing a viewer's eye lands on. The peak-day caption underneath gives
    /// it a second, more boastable data point without competing for
    /// attention (same muted weight as every other secondary label).
    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.monthCost(lang))
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(style.mutedInk)
            Text(Formatting.moneyLabel(data.monthCost))
                .font(.system(size: 58, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [style.ink, style.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            if peakCost > 0 {
                Text(L.peakNd(lang, days: data.daily.count, money: Formatting.moneyLabel(peakCost)))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(style.mutedInk)
            }
        }
    }

    private var statStrip: some View {
        HStack(spacing: 0) {
            shareStat(icon: "dollarsign.circle", label: L.todayCost(lang), value: Formatting.moneyLabel(data.todayCost))
            VSep().padding(.horizontal, 8)
            shareStat(icon: "cube", label: L.monthTokens(lang), value: Formatting.tokenLabel(data.monthTokens))
            VSep().padding(.horizontal, 8)
            shareStat(icon: "doc.text", label: L.shareSessionsLabel(lang), value: "\(data.sessionFileCount)")
        }
        .padding(.vertical, 14).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(style.cardFill))
    }

    private func shareStat(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(style.accent)
                Text(label).font(.system(size: 8.5)).foregroundStyle(style.mutedInk)
            }
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(style.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quotaCard: some View {
        HStack(spacing: 0) {
            StaticRingGauge(
                title: L.sessionTitle(lang),
                hint: data.session?.windowMinutes.map { L.hourWindow(lang, $0 / 60) },
                limit: data.session, lang: lang, style: style
            )
            VSep().padding(.vertical, 6)
            StaticRingGauge(
                title: weeklyLabel,
                hint: data.weekly?.windowMinutes.map { L.dayWindow(lang, $0 / 1440) },
                limit: data.weekly, lang: lang, style: style
            )
        }
        .padding(.vertical, 18).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(style.cardFill))
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.heatmapHint(lang, days: recentDaily.count)).font(.system(size: 10.5)).foregroundStyle(style.mutedInk)
            ShareTrendChart(daily: recentDaily, style: style)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(style.cardFill))
    }

    private var footer: some View {
        HStack {
            Text(generatedDateText).font(.system(size: 9)).foregroundStyle(style.mutedInk)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(style.accent)
                Text("aibar").font(.system(size: 10, weight: .semibold)).foregroundStyle(style.mutedInk)
            }
        }
    }

    private var cardBackground: some View {
        ZStack {
            LinearGradient(colors: style.backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [style.accent.opacity(0.20), .clear], center: .topTrailing, startRadius: 10, endRadius: 460)
            RadialGradient(colors: [style.accent.opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(style.accent.opacity(0.25), lineWidth: 1))
    }
}

/// A non-animated version of `QuotaMeterView`'s ring — the water-fill ripple
/// there depends on `onAppear` kicking off a continuous `TimelineView`
/// animation, which has no well-defined "current frame" when captured through
/// a one-shot `ImageRenderer` snapshot. This draws the same arc + numeral
/// language at rest instead, sized up from the dashboard's own ring since the
/// share card has the room to spare and this is one of its two headline
/// numbers.
private struct StaticRingGauge: View {
    var title: String
    var hint: String?
    var limit: LimitView?
    var lang: AppLanguage
    var style: ShareCardStyle

    private var remaining: Int? {
        guard let used = limit?.usedPercent else { return nil }
        return max(0, Int((100 - used).rounded()))
    }

    private var ringColor: Color {
        QuotaStatusPalette.color(
            remaining: remaining,
            normal: style.accent,
            unavailable: style.mutedInk
        )
    }

    private static let ringSize: CGFloat = 78
    private static let ringWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(style.track, lineWidth: Self.ringWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining ?? 0) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let remaining {
                    Text("\(remaining)%")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(ringColor)
                } else {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 15)).foregroundStyle(style.mutedInk)
                }
            }
            .frame(width: Self.ringSize, height: Self.ringSize)

            VStack(spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(style.ink)
                if let hint {
                    Text(hint).font(.system(size: 9)).foregroundStyle(style.mutedInk)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A smooth gradient-filled area chart for the last two weeks of spend —
/// replaces the old flat bar sparkline with something that reads as a
/// deliberate "trend line" rather than a bar-chart afterthought, which is
/// most of what makes this card look like a poster instead of a cropped
/// screenshot. The full `UsageChartView` heatmap (calendar-week layout, per-
/// cell hover) stays the dashboard's own tool; this is purpose-built for a
/// single still image.
private struct ShareTrendChart: View {
    var daily: [DailyPoint]
    var style: ShareCardStyle

    private static let height: CGFloat = 72
    private var costs: [Double] { daily.map(\.cost) }
    private var maxCost: Double { max(costs.max() ?? 0, 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let points = normalizedPoints(in: geo.size)
                ZStack {
                    areaPath(points, height: geo.size.height)
                        .fill(LinearGradient(colors: [style.accent.opacity(0.38), style.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    linePath(points)
                        .stroke(style.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: Self.height)
            if let first = daily.first, let last = daily.last {
                HStack {
                    Text(shortDate(first.date)).font(.system(size: 8.5)).foregroundStyle(style.mutedInk)
                    Spacer()
                    Text(shortDate(last.date)).font(.system(size: 8.5)).foregroundStyle(style.mutedInk)
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard costs.count > 1 else {
            return costs.map { _ in CGPoint(x: size.width / 2, y: size.height) }
        }
        return costs.enumerated().map { index, cost in
            let x = size.width * CGFloat(index) / CGFloat(costs.count - 1)
            let y = size.height * (1 - CGFloat(cost / maxCost))
            return CGPoint(x: x, y: y)
        }
    }

    /// A simple Bezier interpolation through each point (control handles
    /// held level with their own point, meeting halfway between neighbors) —
    /// smooth enough to read as a trend line without the overshoot a true
    /// spline can introduce on a sharp day-over-day swing.
    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let midX = (p0.x + p1.x) / 2
            path.addCurve(to: p1, control1: CGPoint(x: midX, y: p0.y), control2: CGPoint(x: midX, y: p1.y))
        }
        return path
    }

    private func areaPath(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = linePath(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }

    private func shortDate(_ isoDate: String) -> String { String(isoDate.suffix(5)) }
}
