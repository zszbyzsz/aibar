import SwiftUI
import AppKit

/// Rasterizes `ShareCardView` into an `NSImage` — kept as its own step
/// (rather than inlined at the call site) since it's the one place a
/// `@MainActor` `ImageRenderer` needs to be spun up and torn down. `NSImage`
/// rather than `SwiftUI.Image` so callers can also copy it to the pasteboard
/// or write it to disk, not just hand it to `ShareLink`.
@MainActor
enum ShareCardRenderer {
    static func render(data: UsagePayload, provider: UsageProvider, lang: AppLanguage, style: ShareCardStyle) -> NSImage? {
        let renderer = ImageRenderer(content: ShareCardView(data: data, provider: provider, lang: lang, style: style))
        // 3x the point size roughly matches a Retina screenshot's pixel
        // density, so the shared PNG still looks sharp full-screen on the
        // receiving end (Messages, Mail, social apps) instead of soft.
        renderer.scale = 3
        return renderer.nsImage
    }
}
