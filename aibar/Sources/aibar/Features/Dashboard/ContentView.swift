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
    @State private var usageTimelineStatus: String?
    /// Lets the panel size itself to fit — see `NotchWindowController.setContentHeight`.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Forwarded down to `DashboardHeader`'s share popover — see
    /// `NotchWindowController.setPopoverOpen`.
    var onPopoverStateChange: (Bool) -> Void = { _ in }

    private var data: UsagePayload { store.payload }
    private var lang: AppLanguage { store.language }
    private var weeklyLabel: String { L.weeklyLabel(lang, isMonthly: data.weeklyKind == "monthly") }
    private var usageTimeline: UsageTimeline {
        UsageTimeline(
            daily: data.daily,
            resetCredits: data.rateLimitResetCredits,
            weeklyResetAt: data.weekly?.resetsAt,
            subscriptionEndsAt: data.subscriptionActiveUntil
        )
    }
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
        VStack(alignment: .leading, spacing: 12) {
            DashboardHeader(store: store, onPopoverStateChange: onPopoverStateChange)
            // Attribution is deliberately a two-column desktop group: models
            // need the wider side for pricing and the expanded trend, while
            // projects stay scannable in a narrower companion list. Both
            // lists cap themselves at three visible rows, so panel height
            // stays bounded (see `NotchWindowController.setContentHeight`).
            sections
        }
        .environment(\.appLanguage, lang)
        .foregroundStyle(Color.notchInk)
        // The two header groups flank the physical notch, so they can safely
        // use the otherwise empty top band. Keep the roomier side and bottom
        // padding for the cards below while letting the header sit naturally
        // against the top edge.
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 8)
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
        HStack(alignment: .top, spacing: 0) {
            CompactStat(icon: "dollarsign.circle", label: L.todayCost(lang), value: Formatting.moneyLabel(data.todayCost))
            VSep().padding(.horizontal, 10)
            CompactStat(icon: "calendar", label: L.monthCost(lang), value: Formatting.moneyLabel(data.monthCost), trend: costTrend, judged: true)
            VSep().padding(.horizontal, 10)
            CompactStat(icon: "cube", label: L.monthTokens(lang), value: Formatting.tokenLabel(data.monthTokens), trend: tokenTrend)
            VSep().padding(.horizontal, 10)
            CompactStat(icon: "clock.arrow.circlepath", label: L.latestSessionTokens(lang), value: Formatting.tokenLabel(data.latestSessionTokens))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.notchCardHighlight, Color.notchCardFill],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.notchCardBorder, lineWidth: 1)
        )

        SectionCard(
            title: L.usageOverviewTitle(lang),
            icon: "chart.bar.fill",
            trailing: L.averageDailyTokens30d(
                lang,
                tokens: Formatting.fourSignificantTokenLabel(Double(data.monthTokens) / 30)
            )
        ) {
            // Keep the history dominant: the heatmap owns four fifths of the
            // content row while the live quota summaries share the last fifth.
            // The custom layout uses the available width rather than a fixed
            // sidebar width, so the ratio remains stable as the panel resizes.
            UsageOverviewLayout(leadingShare: 0.75, spacing: 16) {
                UsageChartView(
                    timeline: usageTimeline,
                    onStatusChange: { usageTimelineStatus = $0 }
                )

                VStack(spacing: 0) {
                    CompactQuotaBlock(
                        title: L.dailyLabel(lang), icon: "gauge",
                        hint: nil,
                        limit: data.session,
                        isNarrow: true
                    )
                    CompactQuotaBlock(
                        title: weeklyLabel, icon: "calendar",
                        hint: nil,
                        limit: data.weekly,
                        isNarrow: true
                    )
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.notchRule)
                        .frame(width: 1)
                        .offset(x: -8)
                }
            }
        }
        .overlay(alignment: .top) {
            Text(usageTimelineStatus ?? L.heatmapTimelineHint(lang, days: usageTimeline.points.count))
                .font(.system(size: 10, weight: usageTimelineStatus == nil ? .regular : .semibold))
                .foregroundStyle(usageTimelineStatus == nil ? Color.notchMutedInk : Color.notchAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 360)
                .padding(.top, 19)
                .allowsHitTesting(false)
        }

        attributionCards

        SectionCard(
            title: L.toolActivityTitle(lang),
            icon: "wrench.and.screwdriver.fill",
            trailing: L.last30Days(lang)
        ) {
            ToolActivitySummaryView(
                calls: data.monthToolCalls,
                edits: data.monthFilesChanged,
                tools: data.tools
            )
        }

        if store.provider == .codex, let activity = data.activeProject {
            ProjectActivityMonitorView(activity: activity)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.notchAccent)
                .padding(.top, 1)
            Text(
                data.monthUnpricedModels.isEmpty
                    ? L.footnotePriced(lang)
                    : L.footnoteUnpriced(lang, models: data.monthUnpricedModels.joined(separator: "、"))
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.notchMutedInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)

        if let error = data.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color(red: 1.000, green: 0.720, blue: 0.220))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(red: 1.000, green: 0.720, blue: 0.220).opacity(0.09))
                )
        }
    }

    /// Both attribution cards use identical flexible tracks and one explicit
    /// height. This keeps a true 5:5 split as the panel changes width while
    /// preserving aligned lower edges for their three-row viewports.
    private var attributionCards: some View {
        let cardHeight: CGFloat = 256

        return HStack(alignment: .top, spacing: 10) {
            SectionCard(
                title: L.modelBreakdownTitle(lang),
                icon: "cpu.fill",
                trailing: nil,
                fixedHeight: cardHeight
            ) {
                ModelBreakdownView(
                    models: data.models,
                    rates: data.pricingRates,
                    isCompact: true
                )
            }
            .overlay(alignment: .top) {
                Text(L.hoverForBreakdown(lang))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.notchMutedInk)
                    .padding(.top, 20)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                ModelCompositionLegend()
                    .padding(.top, 19)
                    .padding(.trailing, 14)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            SectionCard(
                title: L.topProjectsTitle(lang),
                icon: "folder.fill",
                trailing: L.projectExpandDetailHint(lang),
                fixedHeight: cardHeight
            ) {
                ProjectListView(projects: data.topProjects)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Splits the usage overview into two predictable tracks without tying either
/// side to a fixed point width. SwiftUI's `Layout` protocol is available on the
/// app's macOS 13 deployment target and preserves each child's natural height.
private struct UsageOverviewLayout: Layout {
    var leadingShare: CGFloat
    var spacing: CGFloat

    private func widths(for totalWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let available = max(0, totalWidth - spacing)
        let share = min(1, max(0, leadingShare))
        let leading = available * share
        return (leading, available - leading)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        guard let proposedWidth = proposal.width else {
            let leading = subviews[0].sizeThatFits(.unspecified)
            let trailing = subviews[1].sizeThatFits(.unspecified)
            return CGSize(
                width: leading.width + spacing + trailing.width,
                height: max(leading.height, trailing.height)
            )
        }

        let split = widths(for: proposedWidth)
        let leading = subviews[0].sizeThatFits(
            ProposedViewSize(width: split.leading, height: proposal.height)
        )
        let trailing = subviews[1].sizeThatFits(
            ProposedViewSize(width: split.trailing, height: proposal.height)
        )
        return CGSize(width: proposedWidth, height: max(leading.height, trailing.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let split = widths(for: bounds.width)

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: split.leading, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + split.leading + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: split.trailing, height: bounds.height)
        )
    }
}
