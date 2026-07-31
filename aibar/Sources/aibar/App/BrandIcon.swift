import AppKit

/// Runtime representations of the aibar brand mark.
///
/// The full-color application icon is supplied by the app bundle, while the
/// menu bar needs a compact template image so macOS can recolor it for the
/// current appearance and highlighted state.
enum BrandIcon {
    static let menuBarSize = NSSize(width: 18, height: 18)

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { _ in
            NSColor.black.setFill()
            archPath.fill()
            usageBarsPath.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static var archPath: NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3, y: 2))
        path.line(to: NSPoint(x: 3, y: 8.6))
        path.curve(
            to: NSPoint(x: 7.2, y: 15.5),
            controlPoint1: NSPoint(x: 3, y: 12.5),
            controlPoint2: NSPoint(x: 5.2, y: 15.5)
        )
        path.line(to: NSPoint(x: 7.2, y: 13.7))
        path.curve(
            to: NSPoint(x: 8.2, y: 12.6),
            controlPoint1: NSPoint(x: 7.2, y: 13),
            controlPoint2: NSPoint(x: 7.6, y: 12.6)
        )
        path.line(to: NSPoint(x: 9.8, y: 12.6))
        path.curve(
            to: NSPoint(x: 10.8, y: 13.7),
            controlPoint1: NSPoint(x: 10.4, y: 12.6),
            controlPoint2: NSPoint(x: 10.8, y: 13)
        )
        path.line(to: NSPoint(x: 10.8, y: 15.5))
        path.curve(
            to: NSPoint(x: 15, y: 8.6),
            controlPoint1: NSPoint(x: 12.8, y: 15.5),
            controlPoint2: NSPoint(x: 15, y: 12.5)
        )
        path.line(to: NSPoint(x: 15, y: 2))
        path.line(to: NSPoint(x: 12.5, y: 2))
        path.line(to: NSPoint(x: 12.5, y: 8.4))
        path.curve(
            to: NSPoint(x: 9, y: 11.1),
            controlPoint1: NSPoint(x: 12.5, y: 10.1),
            controlPoint2: NSPoint(x: 11.1, y: 11.1)
        )
        path.curve(
            to: NSPoint(x: 5.5, y: 8.4),
            controlPoint1: NSPoint(x: 6.9, y: 11.1),
            controlPoint2: NSPoint(x: 5.5, y: 10.1)
        )
        path.line(to: NSPoint(x: 5.5, y: 2))
        path.close()
        return path
    }

    private static var usageBarsPath: NSBezierPath {
        let path = NSBezierPath()
        path.appendRoundedRect(
            NSRect(x: 6.35, y: 2, width: 1.35, height: 2.8),
            xRadius: 0.675,
            yRadius: 0.675
        )
        path.appendRoundedRect(
            NSRect(x: 8.325, y: 2, width: 1.35, height: 4.1),
            xRadius: 0.675,
            yRadius: 0.675
        )
        path.appendRoundedRect(
            NSRect(x: 10.3, y: 2, width: 1.35, height: 5.4),
            xRadius: 0.675,
            yRadius: 0.675
        )
        return path
    }
}
