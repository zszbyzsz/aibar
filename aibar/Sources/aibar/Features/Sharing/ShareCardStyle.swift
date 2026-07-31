import SwiftUI

/// A selectable visual theme for the share-card poster, picked from a swatch
/// row in `ShareSheetView`. Purely cosmetic — it only recolors `ShareCardView`
/// itself, never the live dashboard (`Color.notch*` elsewhere is untouched).
/// A single flat "tech black" card always looks the same no matter how many
/// times someone shares it; a few punchier looks give an actual reason to
/// pick a favorite and post it.
struct ShareCardStyle: Identifiable, Equatable {
    static func == (lhs: ShareCardStyle, rhs: ShareCardStyle) -> Bool { lhs.id == rhs.id }

    let id: String
    let displayName: (AppLanguage) -> String
    /// Two-stop gradient for the card's own background (diagonal, top-leading
    /// to bottom-trailing) — a single color for a flat look works fine too,
    /// just repeat it.
    let backgroundColors: [Color]
    let accent: Color
    let ink: Color
    let mutedInk: Color
    let cardFill: Color
    let track: Color
    let rule: Color
    /// Foreground for the small icon badge in the header, drawn over a
    /// two-stop `accent` gradient — kept separate from `accent` itself since
    /// a light accent (e.g. white) needs a dark icon and vice versa.
    let badgeIcon: Color

    static let midnight = ShareCardStyle(
        id: "midnight",
        displayName: { $0 == .zh ? "午夜" : "Midnight" },
        backgroundColors: [Color.black, Color.black],
        accent: Color.notchAccent,
        ink: Color.notchInk,
        mutedInk: Color.notchMutedInk,
        cardFill: Color.notchCardFill,
        track: Color.notchTrack,
        rule: Color.notchRule,
        badgeIcon: .black
    )

    static let aurora = ShareCardStyle(
        id: "aurora",
        displayName: { $0 == .zh ? "极光" : "Aurora" },
        backgroundColors: [Color(red: 0.055, green: 0.024, blue: 0.180), Color(red: 0.086, green: 0.302, blue: 0.404)],
        accent: Color(red: 0.412, green: 0.906, blue: 0.643),
        ink: .white,
        mutedInk: Color.white.opacity(0.65),
        cardFill: Color.white.opacity(0.13),
        track: Color.white.opacity(0.18),
        rule: Color.white.opacity(0.14),
        badgeIcon: .black
    )

    static let sunset = ShareCardStyle(
        id: "sunset",
        displayName: { $0 == .zh ? "日落" : "Sunset" },
        backgroundColors: [Color(red: 0.867, green: 0.243, blue: 0.376), Color(red: 0.984, green: 0.573, blue: 0.235)],
        accent: .white,
        ink: .white,
        mutedInk: Color.white.opacity(0.78),
        cardFill: Color.black.opacity(0.16),
        track: Color.white.opacity(0.25),
        rule: Color.white.opacity(0.22),
        badgeIcon: Color(red: 0.780, green: 0.180, blue: 0.220)
    )

    static let paper = ShareCardStyle(
        id: "paper",
        displayName: { $0 == .zh ? "简白" : "Paper" },
        backgroundColors: [Color(red: 0.973, green: 0.973, blue: 0.965), Color(red: 0.925, green: 0.937, blue: 0.957)],
        accent: Color(red: 0.055, green: 0.451, blue: 0.949),
        ink: Color(red: 0.078, green: 0.090, blue: 0.110),
        mutedInk: Color(red: 0.400, green: 0.431, blue: 0.471),
        cardFill: Color.black.opacity(0.045),
        track: Color.black.opacity(0.08),
        rule: Color.black.opacity(0.08),
        badgeIcon: .white
    )

    static let all: [ShareCardStyle] = [.midnight, .aurora, .sunset, .paper]
}
