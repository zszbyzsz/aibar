import SwiftUI

/// Picker for `AppLanguage`, styled to match `ProviderSwitcher` so the two
/// pills read as one control family in the header.
struct LanguageSwitcher: View {
    @Binding var selection: AppLanguage

    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    selection = lang
                } label: {
                    if selection == lang {
                        Label(lang.title, systemImage: "checkmark")
                    } else {
                        Text(lang.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe").font(.system(size: 9, weight: .bold))
                Text(selection == .zh ? "中" : "EN").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color.notchInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.notchTrack))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
