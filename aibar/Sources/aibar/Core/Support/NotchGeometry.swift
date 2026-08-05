import AppKit

/// The physical notch's on-screen rect. Shared by every panel that needs to
/// line up with it exactly — the invisible hover hotzone in
/// `NotchWindowController` and the always-on activity capsule in
/// `ActivityStatusBarController` — so the two read as one continuous shape
/// (the notch "growing" a capsule beneath it) rather than two panels that
/// merely happen to sit nearby.
enum NotchGeometry {
    struct QuotaBarLayout: Equatable {
        let frame: CGRect
        let sideContentWidth: CGFloat
        let centerWidth: CGFloat
    }

    /// Extra hover room immediately below the camera housing. The system safe
    /// area describes the physical cutout only; extending downward makes the
    /// otherwise invisible trigger much easier to acquire without changing
    /// the width reported by macOS.
    private static let hoverExtensionBelow: CGFloat = 10

    /// The software capsule used on Macs and displays without a camera
    /// housing. Its proportions follow the range of physical notch widths
    /// macOS reports on current 13/14/16-inch layouts, while staying compact
    /// on small displays and avoiding an oversized bar on wide desktop
    /// monitors. Callers share this value so the quota readout, activity
    /// capsule, and dashboard hotzone never drift to different fallback
    /// widths again.
    static func softwareCapsuleSize(
        screenFrame: CGRect, backingScaleFactor: CGFloat
    ) -> CGSize {
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        // These logical-width anchors mirror the compact camera-housing
        // widths reported by representative 13/14/16-inch layouts. Linear
        // interpolation avoids model-name checks (and keeps working under
        // scaled resolutions), while the endpoints keep arbitrary desktop
        // monitors inside the same proven compact range.
        let widthAnchors: [(screen: CGFloat, capsule: CGFloat)] = [
            (1_280, 176),
            (1_470, 176),
            (1_512, 190),
            (1_728, 204),
        ]
        let clampedScreenWidth = min(1_728, max(1_280, screenFrame.width))
        let upperIndex = widthAnchors.firstIndex {
            $0.screen >= clampedScreenWidth
        } ?? widthAnchors.count - 1
        let interpolatedWidth: CGFloat
        if upperIndex == 0 {
            interpolatedWidth = widthAnchors[0].capsule
        } else {
            let lower = widthAnchors[upperIndex - 1]
            let upper = widthAnchors[upperIndex]
            let progress = (clampedScreenWidth - lower.screen)
                / (upper.screen - lower.screen)
            interpolatedWidth = lower.capsule
                + (upper.capsule - lower.capsule) * progress
        }
        let pixelAlignedWidth = (interpolatedWidth * scale).rounded() / scale
        return CGSize(width: pixelAlignedWidth, height: 32)
    }

    static func softwareCapsuleSize(on screen: NSScreen) -> CGSize {
        softwareCapsuleSize(
            screenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    static func softwareCapsuleFrame(
        screenFrame: CGRect, backingScaleFactor: CGFloat
    ) -> CGRect {
        let size = softwareCapsuleSize(
            screenFrame: screenFrame,
            backingScaleFactor: backingScaleFactor
        )
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func softwareCapsuleFrame(on screen: NSScreen) -> CGRect {
        softwareCapsuleFrame(
            screenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    /// One contiguous frame for the complete top quota bar. A real camera
    /// housing becomes the exact black center of the bar, with one content
    /// wing appended to either side. A display without a housing uses the
    /// shared software-capsule frame and divides that same width between both
    /// readouts and a flexible center. Rendering this as one window avoids
    /// seams and ordering races between independently composited panels.
    static func quotaBarLayout(
        physicalRect: CGRect?,
        screenFrame: CGRect,
        backingScaleFactor: CGFloat,
        physicalSideWidth: CGFloat = 28,
        softwareSideWidth: CGFloat = 40
    ) -> QuotaBarLayout {
        if let physicalRect {
            let sideWidth = max(0, physicalSideWidth)
            return QuotaBarLayout(
                frame: CGRect(
                    x: physicalRect.minX - sideWidth,
                    y: physicalRect.minY,
                    width: physicalRect.width + sideWidth * 2,
                    height: physicalRect.height
                ),
                sideContentWidth: sideWidth,
                centerWidth: physicalRect.width
            )
        }

        let frame = softwareCapsuleFrame(
            screenFrame: screenFrame,
            backingScaleFactor: backingScaleFactor
        )
        let sideWidth = min(max(0, softwareSideWidth), frame.width / 2)
        return QuotaBarLayout(
            frame: frame,
            sideContentWidth: sideWidth,
            centerWidth: max(0, frame.width - sideWidth * 2)
        )
    }

    static func quotaBarLayout(on screen: NSScreen) -> QuotaBarLayout {
        quotaBarLayout(
            physicalRect: physicalRect(on: screen),
            screenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

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
