import SwiftUI

/// A single number in the merged overview strip — no card chrome of its own,
/// separated from its neighbors by a hairline so four numbers read as one row
/// instead of four boxes.
///
/// `trend`, when present, compares the last 7 days against the 7 days before
/// that (both already inside the 30-day window, so no extra history needs to
/// be retained) — a snapshot total doesn't say whether spend is climbing or
/// settling down, and that's the more actionable question. `judged` controls
/// whether the direction gets a good/bad color (cost climbing is worth a
/// warning color) or stays neutral ink (token volume climbing isn't inherently
/// bad, so it only gets an arrow + label, never a red/green judgment).
struct CompactStat: View {
    var icon: String
    var label: String
    var value: String
    var trend: (percent: Int, up: Bool)? = nil
    var judged: Bool = false
    @Environment(\.appLanguage) private var lang

    private var trendColor: Color {
        guard let trend, judged else { return .notchMutedInk }
        return trend.up ? Color(red: 1.000, green: 0.380, blue: 0.420) : Color(red: 0.290, green: 0.960, blue: 0.580)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.notchAccent.opacity(0.12)).frame(width: 22, height: 22)
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.notchAccent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9.5)).foregroundStyle(Color.notchMutedInk)
                Text(value).font(.system(size: 14, weight: .bold))
                if let trend {
                    HStack(spacing: 2) {
                        Image(systemName: trend.up ? "arrow.up" : "arrow.down")
                            .font(.system(size: 7, weight: .bold))
                        Text(L.trendVsPrior7d(lang, abs(trend.percent)))
                            .font(.system(size: 8.5))
                    }
                    .foregroundStyle(trendColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VSep: View {
    var body: some View {
        Rectangle().fill(Color.notchRule).frame(width: 1, height: 24)
    }
}
