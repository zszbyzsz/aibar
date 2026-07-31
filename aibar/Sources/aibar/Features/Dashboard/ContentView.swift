import SwiftUI

/// Fully invisible hover hotzone matching the physical notch — nothing is drawn
/// here at all; it exists only so NotchWindowController can detect a hover-enter
/// over the notch and reveal the dashboard, per the "no shrunken pill" request.
struct IdleHotzoneView: View {
    var body: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reports a view's natural laid-out height up to `NotchWindowController`,
/// which resizes the panel to match — see `DashboardView.body`'s measuring
/// background. `reduce` keeps the latest value; nothing here ever reports
/// more than one height per frame, so first-wins-or-last doesn't matter.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    /// Lets the panel size itself to fit — see `NotchWindowController.setContentHeight`.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Forwarded down to `DashboardHeader`'s share popover — see
    /// `NotchWindowController.setPopoverOpen`.
    var onPopoverStateChange: (Bool) -> Void = { _ in }

    private var data: UsagePayload { store.payload }
    private var lang: AppLanguage { store.language }
    private var weeklyLabel: String { L.weeklyLabel(lang, isMonthly: data.weeklyKind == "monthly") }
    private var hasPriceSource: Bool { data.priceStatus != "fallback" }

    /// Last 7 days vs. the 7 before that, both already covered by the existing
    /// `daily` array (well past the 14 this needs) — no extra history
    /// needs to be scanned/retained to answer "is this climbing or settling
    /// down", which the flat 30-day totals can't answer on their own.
    private func trend(_ value: (DailyPoint) -> Double) -> (percent: Int, up: Bool)? {
        let days = data.daily
        guard days.count >= 14 else { return nil }
        let recent = days.suffix(7).reduce(0) { $0 + value($1) }
        let prior = days.dropLast(7).suffix(7).reduce(0) { $0 + value($1) }
        guard prior > 0.0001 else { return nil }
        let change = (recent - prior) / prior * 100
        return (Int(change.rounded()), change >= 0)
    }
    private var costTrend: (percent: Int, up: Bool)? { trend { $0.cost } }
    private var tokenTrend: (percent: Int, up: Bool)? { trend { Double($0.tokens) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardHeader(store: store, onPopoverStateChange: onPopoverStateChange)
            // Model breakdown and top-projects each cap their own inner list
            // to a fixed "3 rows, then scroll" height, so total content height
            // is bounded without needing an outer scroll here too — the panel
            // just resizes to fit it instead (see the background below and
            // NotchWindowController.setContentHeight).
            sections
        }
        .environment(\.appLanguage, lang)
        .foregroundStyle(Color.notchInk)
        .padding(18)
        // Without this, the background GeometryReader below reports whatever
        // height the hosting NSPanel currently happens to be (it stretches to
        // fill any proposed size), not this content's own ideal height — which
        // defeats the measurement entirely since the panel's height is exactly
        // the thing being decided from that measurement. Fixing vertical sizing
        // here forces SwiftUI to compute and use the real ideal height instead.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { onHeightChange($0) }
    }

    /// Everything below the header — wrapped in the outer `ScrollView` in
    /// `body` above so it can outgrow the fixed window height without losing
    /// cards off the bottom edge.
    @ViewBuilder
    private var sections: some View {
        // The four stat numbers' flat strip now opens the dashboard — it used
        // to sit below the session/weekly cards, but those two moved down
        // into the usage-overview card (see below), so this slides up into
        // the slot they vacated.
        HStack(spacing: 0) {
            CompactStat(icon: "dollarsign.circle", label: L.todayCost(lang), value: Formatting.moneyLabel(data.todayCost))
            VSep().padding(.horizontal, 12)
            CompactStat(icon: "calendar", label: L.monthCost(lang), value: Formatting.moneyLabel(data.monthCost), trend: costTrend, judged: true)
            VSep().padding(.horizontal, 12)
            CompactStat(icon: "cube", label: L.monthTokens(lang), value: Formatting.tokenLabel(data.monthTokens), trend: tokenTrend)
            VSep().padding(.horizontal, 12)
            CompactStat(icon: "clock.arrow.circlepath", label: L.latestSessionTokens(lang), value: Formatting.tokenLabel(data.latestSessionTokens))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.notchCardFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.notchAccent.opacity(0.16), lineWidth: 1))

        SectionCard(title: L.usageOverviewTitle(lang), icon: "chart.bar.fill", trailing: L.peakNd(lang, days: data.daily.count, money: Formatting.moneyLabel(data.daily.map(\.cost).max() ?? 0))) {
            // Session/weekly used to be their own full-width cards up top;
            // they're squeezed down into compact quota blocks here instead,
            // filling the heatmap's right side rather than leaving it blank.
            HStack(alignment: .top, spacing: 16) {
                UsageChartView(daily: data.daily)
                Spacer(minLength: 12)
                VSep()
                VStack(alignment: .leading, spacing: 16) {
                    CompactQuotaBlock(
                        title: L.sessionTitle(lang), icon: "gauge",
                        hint: data.session?.windowMinutes.map { L.hourWindow(lang, $0 / 60) },
                        limit: data.session
                    )
                    CompactQuotaBlock(
                        title: weeklyLabel, icon: "calendar",
                        hint: data.weekly?.windowMinutes.map { L.dayWindow(lang, $0 / 1440) },
                        limit: data.weekly
                    )
                }
                .frame(width: 230)
            }
        }

        SectionCard(
            title: L.modelBreakdownTitle(lang),
            icon: "cpu.fill",
            trailing: hasPriceSource ? L.pricingSynced(lang) : L.pricingOffline(lang)
        ) {
            ModelBreakdownView(models: data.models, rates: data.pricingRates)
        }

        SectionCard(
            title: L.topProjectsTitle(lang),
            icon: "folder.fill",
            trailing: L.toolCallsAndEdits(lang, calls: data.monthToolCalls, edits: data.monthFilesChanged)
        ) {
            ProjectListView(projects: data.topProjects)
        }

        if store.provider == .codex, let activity = data.activeProject {
            ProjectActivityMonitorView(activity: activity)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        Text(
            data.monthUnpricedModels.isEmpty
                ? L.footnotePriced(lang)
                : L.footnoteUnpriced(lang, models: data.monthUnpricedModels.joined(separator: "、"))
        )
        .font(.system(size: 10)).foregroundStyle(Color.notchMutedInk)
        .fixedSize(horizontal: false, vertical: true)

        if let error = data.error {
            Text(error).font(.system(size: 11)).foregroundStyle(Color(red: 1.000, green: 0.720, blue: 0.220))
        }
    }
}
