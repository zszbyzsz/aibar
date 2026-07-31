import SwiftUI
import AppKit

/// The dashboard's controls and account summary. It owns header-only state
/// derivations so `DashboardView` can focus on the usage sections below.
struct DashboardHeader: View {
    @ObservedObject var store: UsageStore
    /// Forwarded up to `NotchWindowController` so the hover auto-close is
    /// suspended while the share popover is open — see `setPopoverOpen`.
    var onPopoverStateChange: (Bool) -> Void = { _ in }
    /// Re-rendered on refresh/language/style change (see the `.onChange`
    /// handlers below), not on every body evaluation — `ImageRenderer` does
    /// real rasterization work, so recomputing it on each hover-driven
    /// re-render would be wasteful for a value that only needs to exist at
    /// the moment someone actually opens the share sheet.
    @State private var cardImage: NSImage?
    @State private var showShareSheet = false
    @State private var shareStyle: ShareCardStyle = .midnight

    private var data: UsagePayload { store.payload }
    private var lang: AppLanguage { store.language }
    private var weeklyLabel: String { L.weeklyLabel(lang, isMonthly: data.weeklyKind == "monthly") }

    private var daysRemaining: Int? {
        guard let until = data.subscriptionActiveUntil else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: until).day
    }

    private var subscriptionBadgeColor: Color {
        guard let days = daysRemaining else { return Color.notchMutedInk }
        if days <= 3 { return Color(red: 1.000, green: 0.380, blue: 0.420) }
        if days <= 10 { return Color(red: 1.000, green: 0.720, blue: 0.220) }
        return Color.notchAccent
    }

    private var subscriptionDateText: String {
        guard let until = data.subscriptionActiveUntil else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: until)
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                controls
                HStack(spacing: 4) {
                    refreshControl
                    Text("·")
                    Text(L.localSessionsCount(lang, count: data.sessionFileCount))
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.notchMutedInk)
            }
            Spacer()
            HStack(spacing: 6) {
                planBadge
                if data.subscriptionActiveUntil != nil {
                    subscriptionBadge
                }
            }
        }
    }

    /// The account tier (pro/plus/free/…) — placed ahead of the renewal badge
    /// so both membership facts read together as one group on the trailing
    /// edge, rather than the tier being buried in the session-count caption.
    private var planBadge: some View {
        Text(data.plan)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.notchInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.notchTrack))
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ProviderSwitcher(selection: $store.provider)
            LanguageSwitcher(selection: $store.language)

            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.notchMutedInk)
                    .padding(5)
                    .background(Circle().fill(Color.notchTrack))
            }
            .buttonStyle(.plain)
            .help(L.shareTooltip(lang))
            .onAppear { refreshCardImage() }
            .onChange(of: data.generatedAt) { _ in refreshCardImage() }
            .onChange(of: lang) { _ in refreshCardImage() }
            .onChange(of: shareStyle) { _ in refreshCardImage() }
            .onChange(of: showShareSheet) { onPopoverStateChange($0) }
            .popover(isPresented: $showShareSheet, arrowEdge: .bottom) {
                ShareSheetView(
                    image: cardImage,
                    providerTitle: store.provider.title,
                    summary: shareSummary,
                    lang: lang,
                    style: $shareStyle
                )
            }
        }
    }

    /// Sits where the plan tier used to read (now moved up next to the
    /// renewal badge) — the sync status is what actually belongs in this
    /// caption row, right beside the session count it's a sibling fact to.
    private var refreshControl: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
                Text(store.refreshing ? L.syncing(lang) : Formatting.updatedAtLabel(data.generatedAt, lang: lang))
            }
        }
        .buttonStyle(.plain)
    }

    private var subscriptionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
            Text(L.subscriptionBadge(lang, date: subscriptionDateText, daysLeft: daysRemaining))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(subscriptionBadgeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(subscriptionBadgeColor.opacity(0.12)))
        .help(L.subscriptionHelp(lang))
    }

    private func refreshCardImage() {
        cardImage = ShareCardRenderer.render(data: data, provider: store.provider, lang: lang, style: shareStyle)
    }

    private var shareSummary: String {
        var lines = [L.shareTitle(lang, provider: store.provider.title)]
        if let session = remainingPercent(data.session) {
            lines.append("\(L.sessionTitle(lang)): \(session)% \(L.remainingWord(lang))")
        }
        if let weekly = remainingPercent(data.weekly) {
            lines.append("\(weeklyLabel): \(weekly)% \(L.remainingWord(lang))")
        }
        lines.append("\(L.todayCost(lang)): \(Formatting.moneyLabel(data.todayCost))")
        lines.append("\(L.monthCost(lang)): \(Formatting.moneyLabel(data.monthCost))")
        lines.append("\(L.monthTokens(lang)): \(Formatting.tokenLabel(data.monthTokens))")
        return lines.joined(separator: "\n")
    }

    private func remainingPercent(_ limit: LimitView?) -> Int? {
        guard let used = limit?.usedPercent else { return nil }
        return max(0, Int((100 - used).rounded()))
    }
}

private struct ProviderSwitcher: View {
    @Binding var selection: UsageProvider

    var body: some View {
        // With a single enabled provider there's nothing to switch between,
        // so skip the menu affordance entirely rather than show a dropdown
        // with one item in it.
        if UsageProvider.enabledCases.count <= 1 {
            Text(selection.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.notchInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.notchTrack))
        } else {
            Menu {
                ForEach(UsageProvider.enabledCases) { provider in
                    Button {
                        selection = provider
                    } label: {
                        if selection == provider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.title).font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.notchInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.notchTrack))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
