import AppKit
import SwiftUI

extension CAMediaTimingFunction {
    /// A soft, barely-there overshoot: the panel eases in, settles just a
    /// hair past its target, then relaxes back — used everywhere a
    /// notch-attached AppKit panel grows or shrinks (NSAnimationContext has
    /// no true spring curve, only timing functions), so those resizes feel
    /// fluid rather than a mechanical linear resize or an obvious bounce.
    static let notchSpring = CAMediaTimingFunction(controlPoints: 0.32, 1.08, 0.15, 1)
}

extension Animation {
    /// The exact same curve and duration as `CAMediaTimingFunction.notchSpring`,
    /// expressed as a SwiftUI `Animation` instead of an AppKit timing
    /// function. When a notch-attached panel's AppKit frame is resized with
    /// one and its SwiftUI content is animated with the other, using two
    /// *different* curves (say, a `.spring(response:dampingFraction:)` on the
    /// SwiftUI side against `.notchSpring` on the AppKit side) makes the two
    /// systems settle at different rates — content that visibly lags or
    /// overtakes the window growing around it. Sharing one set of control
    /// points keeps both engines moving in lockstep.
    static let notchSpring = Animation.timingCurve(0.32, 1.08, 0.15, 1, duration: 0.28)
}

// Dark "tech" palette: true-black cards (flush with the physical notch),
// off-white ink, electric-blue accent.
extension Color {
    static let notchInk = Color(red: 0.902, green: 0.933, blue: 0.960)
    static let notchMutedInk = Color(red: 0.561, green: 0.616, blue: 0.667)
    static let notchRule = Color.white.opacity(0.09)
    static let notchAccent = Color(red: 0.039, green: 0.518, blue: 1.000)
    /// A violet signal reserved for visible screen control. Keeping it out of
    /// the normal blue activity palette makes this state legible even before
    /// the phase label is read.
    static let notchScreenAccent = Color(red: 0.690, green: 0.455, blue: 1.000)
    static let notchAccentSoft = Color(red: 0.039, green: 0.518, blue: 1.000).opacity(0.16)
    static let notchTealSoft = Color(red: 0.039, green: 0.518, blue: 1.000).opacity(0.35)
    static let notchCardFill = Color(red: 0.078, green: 0.090, blue: 0.110)
    /// A slightly lifted top tone gives cards depth against the true-black
    /// panel without introducing a separate surface color or visible gloss.
    static let notchCardHighlight = Color(red: 0.095, green: 0.110, blue: 0.137)
    /// Shared border treatment for metric and section cards. The neutral edge
    /// stays legible on every display while the blue tint preserves the app's
    /// existing identity without outlining every card too loudly.
    static let notchCardBorder = Color.white.opacity(0.10)
    /// Track background for meters/bars — a faint white wash reads as a
    /// recessed groove against the dark card fill.
    static let notchTrack = Color.white.opacity(0.08)
}

/// Shared five-stage quota palette. Keeping the thresholds here ensures the
/// live dashboard and its exported share card communicate the same urgency.
enum QuotaStatusPalette {
    static func color(remaining: Int?, normal: Color, unavailable: Color) -> Color {
        guard let remaining else { return unavailable }

        switch remaining {
        case ...10:
            return Color(red: 1.000, green: 0.380, blue: 0.420) // urgent red
        case ...25:
            return Color(red: 1.000, green: 0.580, blue: 0.180) // orange
        case ...45:
            return Color(red: 1.000, green: 0.800, blue: 0.220) // yellow
        case ...70:
            return Color(red: 0.220, green: 0.840, blue: 0.510) // green
        default:
            return normal // blue / style accent
        }
    }
}

/// Shared corner language for every panel that hangs from the physical notch
/// — the hover dashboard (`NotchWindowController`) and the always-on
/// activity capsule (`ActivityStatusBarController`) both draw their
/// silhouette from here, so the two read as one consistent shape family
/// instead of two separately tuned panels that merely look similar.
enum NotchShape {
    /// Where a panel meets the notch: flush and square — there's no seam to
    /// round there, the panel simply continues the notch's own bottom edge.
    static let attachedRadius: CGFloat = 0
    /// A soft, small round for a panel's top corners when they instead need
    /// to *hug* the notch's own rounded corner rather than square off hard
    /// against it — used on the activity capsule specifically, so its top
    /// corners don't poke a sharp nub past the notch's rounded silhouette.
    static let huggingRadius: CGFloat = 9
    /// The free corners, away from the notch — the dashboard's and the
    /// capsule's bottom corners both share this exact radius.
    static let freeRadius: CGFloat = 18

    /// Flat top (flush with the notch), rounded bottom — the hover
    /// dashboard's silhouette.
    static func attached() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: attachedRadius, bottomLeadingRadius: freeRadius,
            bottomTrailingRadius: freeRadius, topTrailingRadius: attachedRadius
        )
    }

    /// Softly rounded top (hugging the notch's own corner curve), rounded
    /// bottom — the always-on activity capsule's silhouette.
    static func hugging() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: huggingRadius, bottomLeadingRadius: freeRadius,
            bottomTrailingRadius: freeRadius, topTrailingRadius: huggingRadius
        )
    }
}
