import SwiftUI

/// `QuotaMeterView` normally leans on an enclosing `SectionCard` for its
/// title/icon/window-hint header; this gives it the same header in miniature
/// for spots — like the usage-overview card's side column — where a full
/// bordered card per meter would be one box too many.
struct CompactQuotaBlock: View {
    var title: String
    var icon: String
    var hint: String?
    var limit: LimitView?
    var isNarrow: Bool = false
    @Environment(\.appLanguage) private var lang

    private var remaining: Int? {
        guard let used = limit?.usedPercent else { return nil }
        return max(0, Int((100 - used).rounded()))
    }

    private var accentColor: Color {
        QuotaStatusPalette.color(
            remaining: remaining,
            normal: .notchAccent,
            unavailable: .notchMutedInk
        )
    }

    @ViewBuilder
    var body: some View {
        if isNarrow {
            HStack(alignment: .center, spacing: 9) {
                QuotaMeterView(limit: limit, icon: icon, isCompact: true)

                TimelineView(.periodic(from: .now, by: 20)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(title)\(lang == .zh ? "：" : ":")")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.notchInk)
                            .lineLimit(1)

                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                L.remainingWord(lang),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(accentColor.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                            Text(
                                Formatting.refreshRemainingDurationLabel(
                                    limit?.resetsAt,
                                    lang: lang,
                                    now: context.date
                                )
                            )
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.notchInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.notchAccent)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let hint {
                        Text(hint).font(.system(size: 9)).foregroundStyle(Color.notchMutedInk)
                    }
                }
                QuotaMeterView(limit: limit, icon: icon)
            }
        }
    }
}
