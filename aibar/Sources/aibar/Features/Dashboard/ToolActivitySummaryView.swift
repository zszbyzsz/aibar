import SwiftUI

/// A compact two-row activity card. The title, aggregate counters, legend,
/// and period share one header row; the MCP heatmap occupies the second row.
/// This keeps all of the original information while removing the otherwise
/// redundant full-height metrics row.
struct MCPActivityCard: View {
    var calls: Int
    var edits: Int
    var servers: [MCPUsage]

    @Environment(\.appLanguage) private var lang

    private static let callsColor = Color.notchAccent
    private static let editsColor = DashboardSeriesPalette.colors[1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Label {
                    Text(L.mcpActivityTitle(lang))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.notchAccent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.notchAccent.opacity(0.12))
                        )
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()

                VSep()
                    .frame(height: 26)

                CompactToolMetric(
                    icon: "wrench.and.screwdriver.fill",
                    label: L.mcpCallsTitle(lang),
                    value: Formatting.groupedCount(calls),
                    color: Self.callsColor
                )

                VSep()
                    .frame(height: 26)

                CompactToolMetric(
                    icon: "doc.badge.gearshape.fill",
                    label: L.filesChangedTitle(lang),
                    value: Formatting.groupedCount(edits),
                    color: Self.editsColor
                )

                Spacer(minLength: 0)

                if lang == .en {
                    ToolHeatmapLegend()
                }

                Text(L.last30Days(lang))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.notchMutedInk)
                    .lineLimit(1)
                    .fixedSize()
            }

            if servers.isEmpty {
                Text(L.noMCPActivity(lang))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.notchMutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if lang == .zh {
                    HStack(alignment: .top, spacing: 12) {
                        MCPUsageHeatmap(servers: servers)
                            .layoutPriority(1)
                        ToolHeatmapLegend()
                            .fixedSize()
                            .padding(.top, 1)
                    }
                } else {
                    MCPUsageHeatmap(servers: servers)
                }
            }
        }
        .padding(12)
        .dashboardCardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L.mcpCallsAndEdits(
                lang,
                calls: calls,
                edits: edits
            )
        )
    }
}

private enum MCPUsageHeatmapScale {
    /// Square-root scaling retains the count ordering while keeping lightly
    /// used tools visible beside a much more frequently used tool.
    static func brightness(calls: Int, maximum: Int) -> Double {
        guard calls > 0, maximum > 0 else { return 0 }
        return sqrt(min(1, Double(calls) / Double(maximum)))
    }
}

private struct MCPUsageHeatmap: View {
    var servers: [MCPUsage]

    private let columns = [
        GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 8, alignment: .top)
    ]

    private var maximumCalls: Int {
        max(servers.map(\.calls).max() ?? 0, 1)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(servers) { server in
                MCPUsageHeatmapCell(
                    server: server,
                    brightness: MCPUsageHeatmapScale.brightness(
                        calls: server.calls,
                        maximum: maximumCalls
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MCPUsageHeatmapCell: View {
    var server: MCPUsage
    var brightness: Double
    @Environment(\.appLanguage) private var lang

    private var displayName: String {
        server.name
    }

    private var backgroundColor: Color {
        // Every MCP shares one hue: intensity is the only visual encoding.
        // The non-zero floor distinguishes a single observed call from an
        // empty or unavailable square.
        Color.notchAccent.opacity(0.15 + 0.85 * brightness)
    }

    private var tooltip: String {
        "\(displayName): \(Formatting.groupedCount(server.calls)) \(L.mcpCallsTitle(lang).lowercased())"
    }

    private var icon: String {
        let name = server.name.lowercased()
        if name.contains("computer") || name.contains("desktop") || name.contains("node_repl") { return "display" }
        if name.contains("web") || name.contains("browser") { return "globe" }
        if name.contains("git") { return "point.3.connected.trianglepath.dotted" }
        if name.contains("figma") { return "square.grid.2x2" }
        return "externaldrive.connected.to.line.below"
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
                Text(Formatting.groupedCount(server.calls))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(displayName)
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(height: 50)
        .foregroundStyle(Color.notchInk)
        .background(RoundedRectangle(cornerRadius: 9).fill(backgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.12 + 0.18 * brightness), lineWidth: 1)
        )
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tooltip)
    }
}

private struct ToolHeatmapLegend: View {
    @Environment(\.appLanguage) private var lang

    var body: some View {
        HStack(spacing: 4) {
            Text("\(L.mcpCallsTitle(lang)):")
            Text(L.toolHeatmapLow(lang))
            HeatmapLegendSquare(brightness: 0.18)
            HeatmapLegendSquare(brightness: 0.55)
            HeatmapLegendSquare(brightness: 1)
            Text(L.toolHeatmapHigh(lang))
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(Color.notchMutedInk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.toolHeatmapHint(lang))
    }
}

private struct HeatmapLegendSquare: View {
    var brightness: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.notchAccent.opacity(0.15 + 0.85 * brightness))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

private struct CompactToolMetric: View {
    var icon: String
    var label: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.notchMutedInk)
                Text(value)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
            }
        }
        .fixedSize()
    }
}
