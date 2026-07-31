import SwiftUI

/// Per-model usage + live $/1M-token pricing, laid out as a native-feeling list
/// rather than either giant cards or a squeezed one-liner: an identity glyph,
/// a two-line body (name on top; a fixed-size input/cache/output composition
/// glyph + the $/1M rate underneath), and cost + share of total trailing.
/// The composition glyph is always the same width, so it stays legible even
/// when one model dominates spend — length no longer has to fight for the
/// job percentages already do better. Hovering a row swaps the rate line for
/// the exact dollar amount billed in each category.
struct ModelBreakdownView: View {
    var models: [ModelUsage]
    var rates: [String: ModelPrice]
    @State private var hovered: String?
    @Environment(\.appLanguage) private var lang

    static let inputColor = Color(red: 0.165, green: 0.471, blue: 0.839)   // #2a78d6
    static let cachedColor = Color(red: 0.106, green: 0.686, blue: 0.478) // #1baf7a
    static let outputColor = Color(red: 0.922, green: 0.408, blue: 0.204) // #eb6834

    /// Fixed, validated 8-hue categorical order (never cycled independently —
    /// each row keeps its rank's color). Run through the dataviz palette
    /// validator against this card's surface: passes lightness band, chroma
    /// floor, CVD adjacency (worst ΔE 9.1), and normal-vision floor (worst
    /// ΔE 19.6); three hues sit under 3:1 contrast, which is why every row
    /// still carries the model name in text ink rather than colored text.
    private static let palette: [Color] = [
        Color(red: 0.165, green: 0.471, blue: 0.839), // blue   #2a78d6
        Color(red: 0.922, green: 0.408, blue: 0.204), // orange #eb6834
        Color(red: 0.106, green: 0.686, blue: 0.478), // aqua   #1baf7a
        Color(red: 0.929, green: 0.631, blue: 0.000), // yellow #eda100
        Color(red: 0.910, green: 0.482, blue: 0.643), // magenta#e87ba4
        Color(red: 0.000, green: 0.514, blue: 0.000), // green  #008300
        Color(red: 0.290, green: 0.227, blue: 0.655), // violet #4a3aa7
        Color(red: 0.890, green: 0.286, blue: 0.282), // red    #e34948
    ]

    /// Internal identity for the merged "unpriced" row — stable across a
    /// language switch (unlike its displayed label) since it's used for
    /// hover-state and coloring comparisons, not just display.
    private static let unpricedModelKey = "__unpriced__"

    /// Models without a mapped official price each got their own row before,
    /// showing an empty gray bar and "未定价" — visually as heavy as a priced
    /// model but carrying no dollar signal. They're folded into one trailing
    /// "其他" row (token total kept, cost left at 0) so the ranked list stays
    /// about models that actually cost money. The row list itself now scrolls
    /// (see `body`), so there's no need to truncate to a fixed count here —
    /// every priced model shows, in rank order, with the merged row last.
    /// Capped at 13 rows total so the card never grows past "3 visible +
    /// scroll for the rest" — when the merged "其他" row is present it takes
    /// one of the 13 slots, so priced models are trimmed to 12 to make room.
    private var displayed: [ModelUsage] {
        var priced: [ModelUsage] = []
        var unpricedTokens = 0
        for item in models {
            if rates[item.model] != nil {
                priced.append(item)
            } else {
                unpricedTokens += item.tokens
            }
        }
        var result = Array(priced.prefix(unpricedTokens > 0 ? 12 : 13))
        if unpricedTokens > 0 {
            result.append(ModelUsage(model: Self.unpricedModelKey, tokens: unpricedTokens, apiEquivalentCost: 0))
        }
        return result
    }
    private var totalCost: Double { max(models.reduce(0) { $0 + $1.apiEquivalentCost }, 0.000001) }

    private func icon(for model: String) -> String {
        if model == "unknown" || model == Self.unpricedModelKey { return "questionmark.circle.fill" }
        if model.contains("review") { return "eye.fill" }
        if model.contains("mini") { return "bolt.fill" }
        return "sparkles"
    }

    static func displayName(_ model: String, lang: AppLanguage) -> String {
        model == unpricedModelKey ? L.unpricedUsageLabel(lang) : model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                legend(Self.inputColor, L.legendInput(lang))
                legend(Self.cachedColor, L.legendCached(lang))
                legend(Self.outputColor, L.legendOutput(lang))
                Spacer()
                Text(L.hoverForBreakdown(lang)).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
            }
            .padding(.bottom, 9)

            // Fixed-height rows (see ModelRow.rowHeight) so exactly 3 rows show
            // before scrolling kicks in, with the remaining rows (up to the
            // 13-row cap above) reachable by scrolling instead of growing the
            // card unbounded.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle().fill(Color.notchRule).frame(height: 1)
                        }
                        ModelRow(
                            item: item,
                            price: rates[item.model],
                            share: item.apiEquivalentCost / totalCost,
                            color: item.model == Self.unpricedModelKey ? Color.notchMutedInk : Self.palette[index % Self.palette.count],
                            icon: icon(for: item.model),
                            isHovered: hovered == item.model
                        )
                        .onHover { isHovering in hovered = isHovering ? item.model : (hovered == item.model ? nil : hovered) }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: ModelRow.rowHeight * 3 + 2) // 3 rows + the 2 dividers between them
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9.5)).foregroundStyle(Color.notchMutedInk)
        }
    }
}

private struct ModelRow: View {
    var item: ModelUsage
    var price: ModelPrice?
    var share: Double
    var color: Color
    var icon: String
    var isHovered: Bool
    @Environment(\.appLanguage) private var lang

    /// Fixed row height (rather than padding that follows content) so the
    /// enclosing list can size its "3 rows visible" scroll window precisely.
    static let rowHeight: CGFloat = 54

    /// The panel itself never changes width (`NotchWindow.expandedWidth` is a
    /// fixed 720pt — only height follows content), so "80% of the row" has
    /// exactly one value here. A static point width is simpler and steadier
    /// than re-measuring it via GeometryReader on a container that can't
    /// actually change size.
    static let barWidth: CGFloat = 410

    private var categoryTotal: Double { max(item.apiEquivalentCost, 0.000001) }
    private var inputShare: Double { item.inputCost / categoryTotal }
    private var cachedShare: Double { item.cachedCost / categoryTotal }
    private var outputShare: Double { item.outputCost / categoryTotal }

    /// One continuous gradient rather than three abutting rectangles — same
    /// three colors, rendered as a single shape so there's no pixel seam
    /// where they meet, but with a hard (zero-width) cut at each boundary so
    /// only the three actual input/cached/output colors ever show — no
    /// blended fourth/fifth hue in between.
    private var gradientStops: [Gradient.Stop] {
        let segments = [
            (ModelBreakdownView.inputColor, inputShare),
            (ModelBreakdownView.cachedColor, cachedShare),
            (ModelBreakdownView.outputColor, outputShare),
        ].filter { $0.1 > 0.0005 }

        guard !segments.isEmpty else {
            return [.init(color: Color.notchTrack, location: 0), .init(color: Color.notchTrack, location: 1)]
        }

        let blend = 0.0
        var stops: [Gradient.Stop] = []
        var cursor = 0.0
        for (index, (color, share)) in segments.enumerated() {
            let end = index == segments.count - 1 ? 1.0 : min(cursor + share, 1.0)
            stops.append(.init(color: color, location: index == 0 ? 0 : cursor))
            stops.append(.init(color: color, location: min(cursor + blend, end)))
            cursor = end
        }
        stops.append(.init(color: segments.last!.0, location: 1))
        return stops
    }

    /// The two largest input/cached/output shares, called out as small
    /// percentage labels next to the price on hover only — hidden at rest so
    /// the row stays quiet, appearing alongside the per-category dollar
    /// breakdown once you're already asking for detail.
    private var topShareSegments: [(color: Color, share: Double)] {
        [
            (ModelBreakdownView.inputColor, inputShare),
            (ModelBreakdownView.cachedColor, cachedShare),
            (ModelBreakdownView.outputColor, outputShare),
        ]
        .filter { $0.1 > 0.005 }
        .sorted { $0.1 > $1.1 }
        .prefix(2)
        .map { (color: $0.0, share: $0.1) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 26, height: 26)
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ModelBreakdownView.displayName(item.model, lang: lang))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    if let price {
                        Circle()
                            .fill(price.status == "live" ? Color(red: 0.290, green: 0.960, blue: 0.580) : Color.notchMutedInk.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .help(price.status == "live" ? L.liveOfficialPrice(lang) : L.cachedOfflinePrice(lang))
                    }

                    if let price {
                        if isHovered {
                            // Hover swaps the rate for the actual dollars billed
                            // per category plus the top-2 share breakdown — both
                            // stay tucked next to the price, hidden otherwise, so
                            // the row is quiet until you ask for the detail.
                            HStack(spacing: 8) {
                                Text("\(Formatting.moneyLabel(item.inputCost)) · \(Formatting.moneyLabel(item.cachedCost)) · \(Formatting.moneyLabel(item.outputCost))")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.notchAccent)
                                    .lineLimit(1)
                                if !topShareSegments.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(Array(topShareSegments.enumerated()), id: \.offset) { _, seg in
                                            HStack(spacing: 3) {
                                                Circle().fill(seg.color).frame(width: 4, height: 4)
                                                Text("\(Int((seg.share * 100).rounded()))%")
                                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                                    .foregroundStyle(Color.notchMutedInk)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("$\(price.input, specifier: "%.2f")/$\(price.cachedInput, specifier: "%.2f")/$\(price.output, specifier: "%.2f") \(L.per1M(lang))")
                                .font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                                .lineLimit(1)
                        }
                    } else {
                        Text(L.noOfficialPriceMapped(lang))
                            .font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    }

                    Spacer(minLength: 0)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.notchTrack)
                    if let price {
                        LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)
                            .clipShape(Capsule())
                            .opacity(price.status == "live" ? 1 : 0.6)
                    }
                }
                .frame(width: Self.barWidth, height: 6)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if price != nil {
                    Text(Formatting.moneyLabel(item.apiEquivalentCost))
                        .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                } else {
                    Text(L.unpriced(lang))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.notchMutedInk)
                }
                HStack(spacing: 4) {
                    Text(Formatting.tokenLabel(item.tokens))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Color.notchMutedInk)
                    Text("· \(Int((share * 100).rounded()))%")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, isHovered ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? color.opacity(0.07) : Color.clear))
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
