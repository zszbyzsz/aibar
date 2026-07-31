import SwiftUI

struct SectionCard<Content: View>: View {
    var title: String
    var icon: String? = nil
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notchAccent)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Color.notchMutedInk)
                }
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.notchCardFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.notchAccent.opacity(0.16), lineWidth: 1))
    }
}
