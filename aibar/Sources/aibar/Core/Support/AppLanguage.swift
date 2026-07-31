import SwiftUI

/// The dashboard's two supported display languages. Only UI chrome (labels,
/// hints, section titles) switches with this — data pulled straight from scan
/// results (model names, project paths, plan names) is left as-is since it's
/// not ours to translate.
enum AppLanguage: String, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }
    var title: String { self == .zh ? "中文" : "English" }

    private static let defaultsKey = "appLanguage"

    /// Falls back to the system's preferred language on first launch rather
    /// than hard-defaulting to Chinese, so a fresh install already matches
    /// the user's macOS locale.
    static func loadSaved() -> AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), let lang = AppLanguage(rawValue: saved) {
            return lang
        }
        return (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh") ? .zh : .en
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .zh
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
