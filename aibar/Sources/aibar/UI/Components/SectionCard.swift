import SwiftUI

struct SectionCard<Content: View>: View {
    var title: String
    var icon: String? = nil
    var trailing: String?
    var fixedHeight: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.notchAccent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.notchAccent.opacity(0.12))
                        )
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.notchMutedInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            content
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: fixedHeight,
            maxHeight: fixedHeight,
            alignment: .topLeading
        )
        .dashboardCardSurface()
    }
}
