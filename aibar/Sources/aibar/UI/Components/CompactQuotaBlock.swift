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
    @Environment(\.appLanguage) private var lang

    var body: some View {
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
