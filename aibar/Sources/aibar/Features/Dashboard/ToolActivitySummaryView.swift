import SwiftUI

/// A compact activity card for the aggregate counters and each individual
/// tool's 30-day call trend. Tool charts scroll horizontally instead of
/// making the notch-attached dashboard taller than the available screen.
struct ToolActivitySummaryView: View {
    var calls: Int
    var edits: Int
    var tools: [ToolUsage]

    @Environment(\.appLanguage) private var lang

    private static let callsColor = Color.notchAccent
    private static let editsColor = Color(red: 0.922, green: 0.408, blue: 0.204)
    private static let palette: [Color] = [
        Color.notchAccent,
        Color(red: 0.922, green: 0.408, blue: 0.204),
        Color(red: 0.106, green: 0.686, blue: 0.478),
        Color(red: 0.929, green: 0.631, blue: 0.000),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ToolMetric(
                icon: "wrench.and.screwdriver.fill",
                label: L.toolCallsTitle(lang),
                value: Formatting.groupedCount(calls),
                color: Self.callsColor
            )
            .frame(width: 118, alignment: .leading)

            VSep()

            ToolMetric(
                icon: "doc.badge.gearshape.fill",
                label: L.filesChangedTitle(lang),
                value: Formatting.groupedCount(edits),
                color: Self.editsColor
            )
            .frame(width: 112, alignment: .leading)

            VSep()

            if tools.isEmpty {
                Text(L.noToolActivity(lang))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.notchMutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let maxCalls = max(tools.map(\.calls).max() ?? 0, 1)
                // Aggregate counters and per-tool trends now share one row,
                // keeping the card scannable without spending another 58pt
                // of the notch panel's limited vertical budget.
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            ToolUsageTile(
                                tool: tool,
                                color: Self.palette[index % Self.palette.count],
                                maxCalls: maxCalls
                            )
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: 48)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L.toolCallsAndEdits(
                lang,
                calls: calls,
                edits: edits
            )
        )
    }
}

private struct ToolUsageTile: View {
    var tool: ToolUsage
    var color: Color
    var maxCalls: Int
    @Environment(\.appLanguage) private var lang

    private var displayName: String {
        tool.name == "other" ? (lang == .zh ? "其他工具" : "Other tools") : tool.name
    }

    private var icon: String {
        let name = tool.name.lowercased()
        if name.contains("shell") || name.contains("terminal") || name.contains("exec") { return "terminal.fill" }
        if name.contains("patch") || name.contains("edit") || name.contains("write") { return "doc.badge.gearshape.fill" }
        if name.contains("search") || name.contains("web") { return "magnifyingglass" }
        if name.contains("file") || name.contains("read") { return "folder.fill" }
        if name.contains("screen") || name.contains("computer") { return "display" }
        return "wrench.and.screwdriver.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(displayName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(Formatting.groupedCount(tool.calls))
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.notchInk)
            }
            MiniTokenTrendView(values: tool.dailyCalls, color: color, height: 18)
            GeometryReader { geo in
                Capsule().fill(Color.notchTrack)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: max(3, geo.size.width * CGFloat(tool.calls) / CGFloat(maxCalls)))
                    }
            }
            .frame(height: 2)
        }
        .frame(width: 118, height: 46)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.notchTrack.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName): \(Formatting.groupedCount(tool.calls))")
    }
}

private struct ToolMetric: View {
    var icon: String
    var label: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.notchMutedInk)
                Text(value)
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
            }
        }
    }
}
