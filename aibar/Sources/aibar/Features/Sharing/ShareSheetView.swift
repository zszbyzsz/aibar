import SwiftUI
import AppKit

/// The popover shown from the header's share button — a proper preview-first
/// flow instead of dropping straight into the plain system share picker.
/// Leads with the rendered `ShareCardView` image so the user sees exactly
/// what would be posted, then offers "Share to X" as the headline action
/// (macOS has no share-extension API for X, so this copies the image to the
/// pasteboard and opens the web compose box for pasting) with copy/save and
/// the native picker as fallbacks for every other destination.
struct ShareSheetView: View {
    var image: NSImage?
    var providerTitle: String
    var summary: String
    var lang: AppLanguage
    @Binding var style: ShareCardStyle

    @State private var hint: String?

    var body: some View {
        VStack(spacing: 12) {
            Text(L.shareTitle(lang, provider: providerTitle))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.notchInk)

            preview
            styleRow

            VStack(spacing: 8) {
                Button(action: shareToX) {
                    HStack(spacing: 6) {
                        Text("𝕏").font(.system(size: 12, weight: .heavy))
                        Text(L.shareToX(lang)).font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.notchAccent))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    shareActionButton(icon: "doc.on.doc", title: L.shareCopyImage(lang), action: copyImage)
                    shareActionButton(icon: "square.and.arrow.down", title: L.shareSaveImage(lang), action: saveImage)
                }

                nativeSharePicker
            }

            if let hint {
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.notchAccent)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(width: 236)
        .background(Color.black)
        .animation(.easeInOut(duration: 0.2), value: hint)
    }

    private var preview: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(ShareCardView.size, contentMode: .fit)
            } else {
                Rectangle().fill(Color.notchCardFill)
            }
        }
        .frame(width: 204, height: 204 * ShareCardView.size.height / ShareCardView.size.width)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.notchRule, lineWidth: 1))
    }

    /// Lets the poster's own look be picked independently of the live
    /// dashboard's fixed dark theme — see `ShareCardStyle`. Re-rendering on
    /// selection happens up in `DashboardHeader` (it owns the renderer), this
    /// view only reports the choice through the binding.
    private var styleRow: some View {
        VStack(spacing: 6) {
            Text(L.shareStyleLabel(lang)).font(.system(size: 9.5)).foregroundStyle(Color.notchMutedInk)
            HStack(spacing: 10) {
                ForEach(ShareCardStyle.all) { candidate in
                    Button {
                        style = candidate
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: candidate.backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(
                                    candidate == style ? candidate.accent : Color.notchRule,
                                    lineWidth: candidate == style ? 2.5 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(candidate.displayName(lang))
                }
            }
        }
    }

    private func shareActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.notchTrack))
            .foregroundStyle(Color.notchInk)
        }
        .buttonStyle(.plain)
    }

    /// The system picker (Mail, Messages, AirDrop, Notes, Save to Files, any
    /// installed share extension) — kept as the catch-all for every
    /// destination that isn't X, styled to sit quietly under the headline
    /// action rather than being the entire feature.
    private var sharePreviewImage: Image { image.map(Image.init(nsImage:)) ?? Image(systemName: "photo") }

    private var nativeSharePicker: some View {
        ShareLink(
            item: sharePreviewImage,
            subject: Text(L.shareTitle(lang, provider: providerTitle)),
            message: Text(summary),
            preview: SharePreview(Text(L.shareTitle(lang, provider: providerTitle)), image: sharePreviewImage)
        ) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle").font(.system(size: 10, weight: .semibold))
                Text(L.shareMorePlatforms(lang)).font(.system(size: 10.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(Color.notchMutedInk)
        }
        .buttonStyle(.plain)
    }

    private func showHint(_ text: String) {
        hint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if hint == text { hint = nil }
        }
    }

    private func copyImage() {
        guard let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// X's web compose has no URL parameter for attaching an image, so the
    /// standard workaround (used by most share-to-X integrations without an
    /// API key) is to put the image on the pasteboard and let the user paste
    /// it into the compose box that opens. The instruction to paste has to
    /// land *before* the browser takes focus: opening it hands focus to
    /// another app, which can dismiss this popover (and any hint text in it)
    /// before the user ever reads it. A blocking alert the user must
    /// dismiss first guarantees they've seen it regardless of what happens
    /// to this panel's focus afterward.
    private func shareToX() {
        copyImage()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.shareToXAlertTitle(lang)
        alert.informativeText = L.shareToXAlertMessage(lang)
        alert.addButton(withTitle: L.shareToXAlertOpen(lang))
        alert.addButton(withTitle: L.shareToXAlertCancel(lang))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var components = URLComponents(string: "https://twitter.com/intent/tweet")!
        components.queryItems = [URLQueryItem(name: "text", value: summary)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "aibar-\(providerTitle).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
        showHint(L.shareImageSavedHint(lang))
    }
}
