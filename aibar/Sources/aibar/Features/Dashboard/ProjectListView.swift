import SwiftUI

/// Top local project directories by 30-day token usage, from each session's cwd —
/// makes it visible at a glance which workspace is actually driving spend. Each
/// row gets a ranked, colored badge (same visual language as the model list)
/// instead of a flat single-color bar, so the four projects read as a small
/// ranking rather than a plain list.
struct ProjectListView: View {
    var projects: [ProjectUsage]
    @Environment(\.appLanguage) private var lang

    /// Fixed row height (see ModelRow.rowHeight) so exactly 3 rows show
    /// before the list scrolls, matching the model card's behavior.
    static let rowHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 10

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
        // Token counts across projects can span several orders of magnitude;
        // a plain linear bar makes every project but the largest invisible,
        // so this compresses the scale with sqrt while keeping the ordering.
        let maxScale = max(sqrt(Double(projects.map(\.tokens).max() ?? 0)), 1)
        if projects.isEmpty {
            Text(L.noProjectData(lang)).font(.system(size: 11)).foregroundStyle(Color.notchMutedInk)
        } else {
            // Fixed-height rows so exactly 3 show before scrolling kicks in,
            // with the remaining projects (up to the 12-project cap set
            // upstream) reachable by scrolling instead of growing the card.
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        let color = Self.palette[index % Self.palette.count]
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(color.opacity(0.15)).frame(width: 22, height: 22)
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(project.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(Formatting.tokenLabel(project.tokens)).font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(Color.notchMutedInk)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Color.notchTrack)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(color)
                                                .frame(width: max(4, geo.size.width * CGFloat(sqrt(Double(project.tokens)) / maxScale)))
                                        }
                                }
                                .frame(height: 5)
                            }
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: Self.rowHeight * 3 + Self.rowSpacing * 2)
        }
    }
}
