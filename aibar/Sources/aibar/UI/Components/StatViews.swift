import SwiftUI

/// A single number in the merged overview strip. Each stat keeps its icon,
/// label, and optional comparison on one quiet line, then gives the value a
/// full second line. This keeps every column at two rows in both languages.
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
        return trend.up ? .notchDanger : .notchSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.notchAccent)
                    .frame(width: 19, height: 19)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.notchAccent.opacity(0.12))
                    )
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.notchMutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .help(label)

                Spacer(minLength: 2)

                if let trend {
                    HStack(spacing: 3) {
                        Image(systemName: trend.up ? "arrow.up" : "arrow.down")
                            .font(.system(size: 7, weight: .bold))
                        Text(L.trendVsPrior7d(lang, abs(trend.percent)))
                            .font(.system(size: 8.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(trendColor)
                    .layoutPriority(1)
                }
            }

            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

struct VSep: View {
    var height: CGFloat = 42

    var body: some View {
        Rectangle().fill(Color.notchRule).frame(width: 1, height: height)
    }
}
