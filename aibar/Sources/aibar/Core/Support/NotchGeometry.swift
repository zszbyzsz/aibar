import AppKit

/// The physical notch's on-screen rect. Shared by every panel that needs to
/// line up with it exactly — the invisible hover hotzone in
/// `NotchWindowController` and the always-on activity capsule in
/// `ActivityStatusBarController` — so the two read as one continuous shape
/// (the notch "growing" a capsule beneath it) rather than two panels that
/// merely happen to sit nearby.
enum NotchGeometry {
    /// Real notch geometry comes from the two auxiliary safe-area rects macOS
    /// reports beside the camera housing; the gap between them is the
    /// physical cutout. On a display without a notch, this falls back to a
    /// small centered placeholder of `fallbackSize` instead.
    static func rect(on screen: NSScreen, fallbackSize: CGSize) -> CGRect {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notchWidth = frame.width - left.width - right.width
            let notchHeight = screen.safeAreaInsets.top
            if notchWidth > 0, notchHeight > 0 {
                let width = max(notchWidth, fallbackSize.width)
                let height = notchHeight + 10
                return CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
            }
        }
        return CGRect(
            x: frame.midX - fallbackSize.width / 2, y: frame.maxY - fallbackSize.height,
            width: fallbackSize.width, height: fallbackSize.height
        )
    }

    /// Frames for compact, always-visible readouts immediately beside the
    /// camera housing.  The height comes from the same safe-area-derived
    /// notch rect used by the dashboard, rather than a hard-coded menu-bar
    /// height, so it stays flush on each MacBook display configuration.
    static func sideFrames(
        on screen: NSScreen, width: CGFloat, inset: CGFloat = 0,
        fallbackSize: CGSize
    ) -> (left: CGRect, right: CGRect) {
        let notch = rect(on: screen, fallbackSize: fallbackSize)
        // `rect` extends 10pt below the cutout for the dashboard's easier
        // hover target. The side readouts intentionally use the physical
        // safe-area height itself, as they live alongside—not below—the
        // camera housing.
        let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : notch.height
        let y = screen.frame.maxY - height
        return (
            left: CGRect(x: notch.minX - width + inset, y: y, width: width, height: height),
            right: CGRect(x: notch.maxX - inset, y: y, width: width, height: height)
        )
    }

    /// The tallest a panel hung `gap` beneath `notch` may be drawn before it
    /// would run off the bottom of the display, floored at `minimum` so one
    /// row is always permitted even on an implausibly short screen.
    ///
    /// Measured *downward* from the notch's bottom edge, which is the
    /// direction such a panel actually extends. Deriving it the other way
    /// round (screen height minus `notch.minY`) yields the sliver of screen
    /// ABOVE the notch — a couple of tens of points — and since that is always
    /// shorter than a single row, `minimum` then swallows it and pins every
    /// result to exactly one row's height, silently making a multi-row stack
    /// unable to grow at all.
    static func availableHeightBelow(
        notch: CGRect, screenFrame: CGRect, gap: CGFloat,
        bottomMargin: CGFloat = 20, minimum: CGFloat
    ) -> CGFloat {
        max(minimum, notch.minY - screenFrame.minY - gap - bottomMargin)
    }
}
