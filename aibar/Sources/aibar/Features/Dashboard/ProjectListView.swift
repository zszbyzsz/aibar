import SwiftUI

/// Top local project directories by normalized 90-day token usage, from each session's cwd —
/// makes it visible at a glance which workspace is actually driving spend. Each
/// row gets a ranked, colored badge (same visual language as the model list)
/// instead of a flat single-color bar, so the four projects read as a small
/// ranking rather than a plain list.
struct ProjectListView: View {
    var projects: [ProjectUsage]
    @Environment(\.appLanguage) private var lang
    @State private var expandedProject: String?

    /// Fixed row height (see ModelRow.rowHeight) so exactly 3 rows show
    /// before the list scrolls, matching the model card's behavior.
    static let rowHeight: CGFloat = 64
    /// Match the compact model card's legend + three-row viewport so both
    /// attribution cards retain one continuous lower edge even when there are
    /// fewer than three projects to show.
    static let compactCardContentHeight: CGFloat = 218

    /// Same validated 8-hue order as the model list (first 4 slots), so a
    /// project and a model never accidentally share a color language while
    /// meaning different things.
    private static let palette: [Color] = [
        Color(red: 0.165, green: 0.471, blue: 0.839), // blue   #2a78d6
        Color(red: 0.922, green: 0.408, blue: 0.204), // orange #eb6834
        Color(red: 0.106, green: 0.686, blue: 0.478), // aqua   #1baf7a
        Color(red: 0.929, green: 0.631, blue: 0.000), // yellow #eda100
    ]

    var body: some View {
        if projects.isEmpty {
            Text(L.noProjectData(lang))
                .font(.system(size: 11))
                .foregroundStyle(Color.notchMutedInk)
                .frame(maxWidth: .infinity, minHeight: Self.compactCardContentHeight, alignment: .center)
        } else {
            // Fixed-height rows so exactly 3 show before scrolling kicks in,
            // with the remaining projects (up to the 12-project cap set
            // upstream) reachable by scrolling instead of growing the card.
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 {
                            Rectangle().fill(Color.notchRule).frame(height: 1)
                        }
                        let color = Self.palette[index % Self.palette.count]
                        ProjectRow(
                            project: project,
                            rank: index + 1,
                            rankColor: color,
                            isExpanded: expandedProject == project.id,
                            toggleExpansion: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    expandedProject = expandedProject == project.id ? nil : project.id
                                }
                            }
                        )
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: Self.rowHeight * 3 + 2)
            .frame(maxWidth: .infinity, minHeight: Self.compactCardContentHeight, alignment: .topLeading)
        }
    }
}

private struct ProjectRow: View {
    var project: ProjectUsage
    var rank: Int
    var rankColor: Color
    var isExpanded: Bool
    var toggleExpansion: () -> Void
    @Environment(\.appLanguage) private var lang

    private static let modelPalette: [Color] = [
        Color(red: 0.165, green: 0.471, blue: 0.839),
        Color(red: 0.922, green: 0.408, blue: 0.204),
        Color(red: 0.106, green: 0.686, blue: 0.478),
        Color(red: 0.929, green: 0.631, blue: 0.000),
        Color(red: 0.910, green: 0.482, blue: 0.643),
        Color(red: 0.290, green: 0.227, blue: 0.655),
    ]

    private func modelColor(at index: Int) -> Color {
        Self.modelPalette[index % Self.modelPalette.count]
    }

    private var projectName: String {
        project.name == UsageAggregation.unattributedProject
            ? L.unattributedProject(lang)
            : project.name
    }

    private var modelSummary: String {
        let names = project.models.prefix(2).map(\.model)
        return names.isEmpty ? L.noOfficialPriceMapped(lang) : names.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleExpansion) {
                HStack(alignment: .top, spacing: 9) {
                    ZStack {
                        Circle().fill(rankColor.opacity(0.15)).frame(width: 24, height: 24)
                        Text("\(rank)")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(rankColor)
                    }

                    // Just like the model list, the row's trend and usage
                    // strip span the full content width underneath both the
                    // project label and its total price.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(projectName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    if !project.models.isEmpty {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundStyle(Color.notchMutedInk)
                                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(modelSummary)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(Color.notchMutedInk)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            spendingSummary
                        }

                        MiniTokenTrendView(values: project.dailyTokens, color: rankColor, height: 22)
                            .help(L.projectTokenTrendHint(lang))
                        compositionBar
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.projectUsageAccessibilityLabel(lang, project: projectName, tokens: Formatting.tokenLabel(project.tokens)))
            .help(project.models.isEmpty ? "" : L.projectModelBreakdownHint(lang))

            if isExpanded, !project.models.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.projectModelBreakdownTitle(lang))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.notchMutedInk)
                    ForEach(Array(project.models.enumerated()), id: \.element.id) { index, model in
                        HStack(spacing: 6) {
                            Circle().fill(modelColor(at: index)).frame(width: 6, height: 6)
                            Text(model.model).font(.system(size: 10.5)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(
                                L.projectModelShare(
                                    lang,
                                    tokens: Formatting.tokenLabel(model.tokens),
                                    percent: Double(model.tokens) * 100.0 / Double(max(project.tokens, 1))
                                ) + " · " + Formatting.moneyLabel(model.apiEquivalentCost)
                            )
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Color.notchMutedInk)
                        }
                    }
                }
                .padding(.leading, 32)
            }
        }
        .frame(minHeight: ProjectListView.rowHeight)
    }

    private var spendingSummary: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(Formatting.moneyLabel(project.apiEquivalentCost))
                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
            Text("\(Formatting.tokenLabel(project.tokens)) token")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Color.notchMutedInk)
        }
    }

    private var compositionBar: some View {
        GeometryReader { geo in
            Capsule().fill(Color.notchTrack)
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        if project.models.isEmpty {
                            Capsule().fill(rankColor)
                                .frame(width: geo.size.width)
                        } else {
                            ForEach(Array(project.models.enumerated()), id: \.element.id) { index, model in
                                Rectangle()
                                    .fill(modelColor(at: index))
                                    .frame(width: geo.size.width * CGFloat(model.tokens) / CGFloat(max(project.tokens, 1)))
                            }
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .clipShape(Capsule())
                }
        }
        .frame(height: 3)
    }
}
