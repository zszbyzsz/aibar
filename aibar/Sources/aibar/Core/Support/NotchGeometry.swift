import AppKit

/// The physical notch's on-screen rect. Shared by every panel that needs to
/// line up with it exactly — the invisible hover hotzone in
/// `NotchWindowController` and the always-on activity capsule in
/// `ActivityStatusBarController` — so the two read as one continuous shape
/// (the notch "growing" a capsule beneath it) rather than two panels that
/// merely happen to sit nearby.
enum NotchGeometry {
    /// Extra hover room immediately below the camera housing. The system safe
    /// area describes the physical cutout only; extending downward makes the
    /// otherwise invisible trigger much easier to acquire without changing
    /// the width reported by macOS.
    private static let hoverExtensionBelow: CGFloat = 10

    /// The display that should own every notch-attached surface. Accessory
    /// apps do not reliably have a key window, so `NSScreen.main` can be nil or
    /// point at an external display. Prefer a real notched display and only
    /// fall back to the normal main/first-screen behavior when no display
    /// reports notch geometry.
    static func targetScreen() -> NSScreen? {
        if let main = NSScreen.main, physicalRect(on: main) != nil {
            return main
        }
        return NSScreen.screens.first(where: { physicalRect(on: $0) != nil })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Exact physical camera-housing rect reported by macOS. The two
    /// auxiliary areas are the usable menu-bar regions immediately to the left
    /// and right of the housing, so the gap between their *coordinates* is the
    /// authoritative width. Deriving it from the whole screen width or forcing
    /// a minimum width makes different MacBook models and scaled resolutions
    /// disagree with the actual cutout.
    static func physicalRect(on screen: NSScreen) -> CGRect? {
        physicalRect(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    /// Pure geometry counterpart used by tests and by `physicalRect(on:)`.
    /// Auxiliary-area rectangles are in the global screen coordinate space,
    /// which matters when the built-in display is not at origin `(0, 0)`.
    static func physicalRect(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea left: CGRect?,
        auxiliaryTopRightArea right: CGRect?
    ) -> CGRect? {
        guard safeAreaTop.isFinite, safeAreaTop > 0,
              let left, let right
        else { return nil }

        let minX = max(screenFrame.minX, left.maxX)
        let maxX = min(screenFrame.maxX, right.minX)
        let width = maxX - minX
        guard minX.isFinite, maxX.isFinite, width.isFinite, width > 0 else {
            return nil
        }

        return CGRect(
            x: minX,
            y: screenFrame.maxY - safeAreaTop,
            width: width,
            height: safeAreaTop
        )
    }

    /// Real notch geometry comes from the two auxiliary safe-area rects macOS
    /// reports beside the camera housing; the gap between them is the
    /// physical cutout. On a display without a notch, this falls back to a
    /// small centered placeholder of `fallbackSize` instead.
    static func rect(on screen: NSScreen, fallbackSize: CGSize) -> CGRect {
        hoverRect(
            physicalRect: physicalRect(on: screen),
            screenFrame: screen.frame,
            fallbackSize: fallbackSize
        )
    }

    static func hoverRect(
        physicalRect: CGRect?,
        screenFrame: CGRect,
        fallbackSize: CGSize,
        extensionBelow: CGFloat = hoverExtensionBelow
    ) -> CGRect {
        if let physicalRect {
            let extensionBelow = max(0, extensionBelow)
            return CGRect(
                x: physicalRect.minX,
                y: physicalRect.minY - extensionBelow,
                width: physicalRect.width,
                height: physicalRect.height + extensionBelow
            )
        }

        return CGRect(
            x: screenFrame.midX - fallbackSize.width / 2,
            y: screenFrame.maxY - fallbackSize.height,
            width: fallbackSize.width,
            height: fallbackSize.height
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
        let height = physicalRect(on: screen)?.height ?? notch.height
        let y = screen.frame.maxY - height
        return (
            left: CGRect(x: notch.minX - width + inset, y: y, width: width, height: height),
            right: CGRect(x: notch.maxX - inset, y: y, width: width, height: height)
        )
    }

    /// The software-only black bridge that stands in for the camera housing
    /// in macOS screenshots. It uses only the system menu-bar thickness (not
    /// the full safe area or hover target) and returns nil on displays without
    /// a real notch, so an external monitor never gains a synthetic cutout.
    static func cameraBridgeFrame(on screen: NSScreen) -> CGRect? {
        guard let physicalRect = physicalRect(on: screen) else { return nil }

        return cameraBridgeFrame(
            notch: physicalRect,
            screenFrame: screen.frame,
            physicalHeight: min(physicalRect.height, NSStatusBar.system.thickness)
        )
    }

    static func cameraBridgeFrame(
        notch: CGRect, screenFrame: CGRect, physicalHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: notch.minX,
            y: screenFrame.maxY - physicalHeight,
            width: notch.width,
            height: physicalHeight
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
