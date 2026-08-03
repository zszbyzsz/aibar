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

    @ViewBuilder
    var body: some View {
        if isNarrow {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(title)\(lang == .zh ? "：" : ":")")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.notchInk)
                    .lineLimit(1)

                HStack(alignment: .center, spacing: 10) {
                    // Keep the quota itself anchored to the left so the larger
                    // refresh readout can use the full remaining width instead
                    // of being squeezed into the title row.
                    QuotaMeterView(limit: limit, icon: icon, isCompact: true)

                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(
                                L.remainingWord(lang),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.notchMutedInk)

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
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
